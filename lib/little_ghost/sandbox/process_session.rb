# frozen_string_literal: true

module LittleGhost
  class Sandbox
    # Owns one sandboxed child process and its bounded input and output streams.
    # Timeout, cancellation, and close terminate the original process group and
    # its ordinary descendants. A descendant that creates another process group
    # can outlive this session. Use a backend with +process_tree_ownership+ or an
    # outer supervisor when complete descendant ownership is required.
    #
    # When +memory_bytes+ is configured, the parent samples the visible process
    # tree every 100 milliseconds. This guard may miss memory peaks between
    # samples. On Linux, three consecutive failures to read the root process or
    # the +/proc+ snapshot end the process. Use an outer cgroup or container when
    # memory needs a hard kernel-enforced limit.
    class ProcessSession
      Chunk = Data.define(:stdout, :stderr, :eof) # :nodoc:
      MEMORY_SAMPLE_INTERVAL = 0.1
      MEMORY_SUPERVISION_FAILURE_LIMIT = 3

      private_constant :MEMORY_SAMPLE_INTERVAL, :MEMORY_SUPERVISION_FAILURE_LIMIT

      # Starts +command+ in a new process group with a scrubbed environment by
      # default. +output_bytes+ bounds combined standard output and error.
      # Optional CPU, file-size, and sampled-memory limits apply to the child.
      def initialize(command:, environment: {}, inherit_environment: false, chdir: nil,
        output_bytes: 1_000_000, memory_bytes: nil, memory_reader: nil, cpu_seconds: nil, file_bytes: nil)
        @output_bytes = Integer(output_bytes)
        raise ArgumentError, "output_bytes must be positive" unless @output_bytes.positive?
        @memory_bytes = memory_bytes && Integer(memory_bytes)
        @memory_reader = memory_reader || default_memory_reader if @memory_bytes

        @stdin_r, @stdin_w = IO.pipe
        @stdout_r, @stdout_w = IO.pipe
        @stderr_r, @stderr_w = IO.pipe
        options = {
          in: @stdin_r,
          out: @stdout_w,
          err: @stderr_w,
          pgroup: true,
          unsetenv_others: !inherit_environment
        }
        options[:chdir] = chdir if chdir
        options[:rlimit_cpu] = [Integer(cpu_seconds), Integer(cpu_seconds)] if cpu_seconds
        options[:rlimit_fsize] = [Integer(file_bytes), Integer(file_bytes)] if file_bytes
        @pid = Process.spawn(
          environment.transform_keys(&:to_s).transform_values(&:to_s),
          *Array(command).map(&:to_s),
          **options
        )
        @stdin_r.close
        @stdout_w.close
        @stderr_w.close
        @captured_bytes = 0
        @status = nil
        @closed = false
        @reap_mutex = Mutex.new
        @write_mutex = Mutex.new
        @memory_monitor = Thread.new { monitor_memory } if @memory_bytes
      rescue
        [@stdin_r, @stdin_w, @stdout_r, @stdout_w, @stderr_r, @stderr_w].compact.each do |io|
          io.close unless io.closed?
        rescue IOError
          nil
        end
        raise
      end

      # Operating-system process ID of the command process.
      attr_reader :pid

      # Whether the command process or its original process group is still
      # alive. Raises when resource supervision failed.
      def alive?
        raise @resource_error if @resource_error

        raw_alive?
      end

      # Writes +value+ to the child's standard input.
      def write(value)
        raise IOError, "process session is closed" if @closed

        @write_mutex.synchronize do
          @stdin_w.write(String(value))
          @stdin_w.flush
        end
      rescue Errno::EPIPE
        raise IOError, "sandboxed process has exited"
      end

      # Closes the child's standard input without ending the process.
      def close_write
        @stdin_w.close unless @stdin_w.closed?
      end

      # Reads currently available output, waiting for at most +timeout+ seconds.
      def read(timeout: 0)
        deadline = monotonic_time + Float(timeout)
        stdout = +""
        stderr = +""
        loop do
          readers = [@stdout_r, @stderr_r].reject(&:closed?)
          break if readers.empty?

          remaining = [deadline - monotonic_time, 0].max
          ready = IO.select(readers, nil, nil, remaining)
          break unless ready

          ready.first.each do |io|
            chunk = io.read_nonblock(16_384, exception: false)
            if chunk.nil?
              io.close
            elsif chunk != :wait_readable
              consume!(chunk)
              (io.equal?(@stdout_r) ? stdout : stderr) << chunk
            end
          end
          break if timeout.to_f.zero?
          break if monotonic_time >= deadline
        end
        Chunk.new(stdout:, stderr:, eof: !alive? && [@stdout_r, @stderr_r].all?(&:closed?))
      end

      # Waits for completion and returns the child's Process::Status. When
      # +terminate+ is true, expiry stops the whole process group before raising.
      def wait(timeout: nil, context: nil, terminate: true)
        deadline = timeout && monotonic_time + Float(timeout)
        while alive?
          context&.check!
          if deadline && monotonic_time >= deadline
            self.terminate if terminate
            raise ToolError, "Program timed out after #{timeout} seconds"
          end
          sleep(0.01)
        end
        @status
      rescue
        self.terminate if terminate
        raise
      end

      # Requests termination, forces it when needed, and returns the child's
      # Process::Status when available.
      def terminate
        return @status unless @pid

        if process_group_alive?
          signal_group("TERM")
          deadline = monotonic_time + 0.5
          sleep(0.01) while process_group_alive? && monotonic_time < deadline
          signal_group("KILL") if process_group_alive?
        end
        reap(true)
        @status
      end

      # Terminates the process when needed and closes every owned stream.
      # Calling +close+ more than once is safe.
      def close
        return if @closed

        terminate if raw_alive?
        @closed = true
        @memory_monitor&.kill unless @memory_monitor.equal?(Thread.current)
        [@stdin_w, @stdout_r, @stderr_r].each { |io| io.close unless io.closed? }
        nil
      rescue IOError, ToolError
        signal_group("KILL") if @pid
        nil
      end

      private

      def monitor_memory
        consecutive_failures = 0
        loop do
          break unless raw_alive?

          memory_bytes = nil
          begin
            memory_bytes = @memory_reader.call(@pid)
            consecutive_failures = 0
          rescue => error
            consecutive_failures += 1
            if consecutive_failures >= MEMORY_SUPERVISION_FAILURE_LIMIT
              fail_memory_supervision(error)
              break
            end
          end

          if memory_bytes && memory_bytes > @memory_bytes
            @resource_error = ToolError.new("Program memory exceeded #{@memory_bytes} bytes")
            signal_group("TERM")
            sleep(MEMORY_SAMPLE_INTERVAL)
            signal_group("KILL") if raw_alive?
            break
          end

          sleep(MEMORY_SAMPLE_INTERVAL)
        end
      rescue => error
        fail_memory_supervision(error)
      end

      def fail_memory_supervision(cause)
        @resource_error ||= begin
          raise ToolError, "Program memory supervisor failed (#{cause.class.name || "anonymous exception"})", cause: cause
        rescue ToolError => error
          error
        end
        signal_group("KILL")
      end

      def default_memory_reader
        if RUBY_PLATFORM.include?("linux")
          raise DependencyError, "process memory supervision requires /proc" unless File.directory?("/proc") && File.readable?("/proc")

          method(:linux_process_tree_rss)
        elsif RUBY_PLATFORM.include?("darwin")
          raise DependencyError, "process memory supervision requires /bin/ps" unless File.executable?("/bin/ps")

          method(:darwin_process_tree_rss)
        else
          raise UnsupportedPlatformError, "process memory supervision is unavailable on #{RUBY_PLATFORM}"
        end
      end

      def linux_process_tree_rss(root_pid)
        entries = linux_process_entries
        root_process = read_linux_process(root_pid.to_s)
        unless root_process
          cause = ArgumentError.new("malformed root process status")
          raise DependencyError, "process memory supervisor cannot read root process /proc/#{root_pid}/status", cause: cause
        end

        processes = entries.filter_map do |entry|
          next unless /\A\d+\z/.match?(entry)
          next root_process if entry == root_pid.to_s

          read_linux_process(entry)
        rescue SystemCallError, IOError
          nil
        end
        processes << root_process unless entries.include?(root_pid.to_s)
        descendant_rss(processes, root_pid)
      rescue SystemCallError, IOError => error
        raise DependencyError, "process memory supervisor cannot read root process /proc/#{root_pid}/status", cause: error
      end

      def linux_process_entries
        Dir.children("/proc")
      rescue SystemCallError, IOError => error
        raise DependencyError, "process memory supervisor cannot snapshot /proc", cause: error
      end

      def read_linux_process(entry)
        status = File.read("/proc/#{entry}/status")
        ppid = Integer(status[/^PPid:\s+(\d+)/, 1], exception: false)
        rss = Integer(status[/^VmRSS:\s+(\d+)\s+kB/, 1], exception: false)
        [Integer(entry), ppid, rss * 1024] if ppid && rss
      end

      def darwin_process_tree_rss(root_pid)
        output = IO.popen(["/bin/ps", "-axo", "pid=,ppid=,rss="], err: File::NULL, &:read)
        processes = output.lines.filter_map do |line|
          pid, ppid, rss = line.split.map { |value| Integer(value, exception: false) }
          [pid, ppid, rss * 1024] if pid && ppid && rss
        end
        raise DependencyError, "process memory supervisor returned no process data" if processes.empty?

        descendant_rss(processes, root_pid)
      end

      def descendant_rss(processes, root_pid)
        selected = {root_pid => true}
        loop do
          added = false
          processes.each do |pid, ppid, _rss|
            next if selected[pid] || !selected[ppid]

            selected[pid] = true
            added = true
          end
          break unless added
        end
        processes.sum { |pid, _ppid, rss| selected[pid] ? rss : 0 }
      end

      def raw_alive?
        reap(false)
        @status.nil? || process_group_alive?
      end

      def consume!(chunk)
        @captured_bytes += chunk.bytesize
        if @captured_bytes > @output_bytes
          terminate
          raise ToolError, "Program output exceeded #{@output_bytes} bytes"
        end
      end

      def reap(blocking)
        @reap_mutex.synchronize do
          return @status if @status

          pid, status = Process.waitpid2(@pid, blocking ? 0 : Process::WNOHANG)
          @status = status if pid
          @status
        end
      rescue Errno::ECHILD
        @status
      end

      def signal_group(signal)
        Process.kill(signal, -@pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def process_group_alive?
        Process.kill(0, -@pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
