# frozen_string_literal: true

require "open3"

module LittleGhost
  # UnrestrictedSandbox is a convenient host-backed sandbox for trusted local
  # work. It offers bounded text-file operations and command execution using only
  # Ruby's standard library.
  #
  #   workspace = LittleGhost::Workspace.new(root: Dir.pwd)
  #   sandbox = LittleGhost::UnrestrictedSandbox.new(workspace:)
  #   sandbox.read("README.md").lines.first # => "# LittleGhost\n"
  #
  # Reads return valid UTF-8 text. Writes preserve the supplied String bytes.
  # Paths must be relative, may not contain +..+, and are checked against the
  # configured workspace root.
  #
  # === Security and trust
  #
  # This sandbox is not a security boundary. Commands run directly on the host
  # with the Ruby process's permissions, and filesystem containment cannot defend
  # against concurrent adversarial mutation. Use an isolated Sandbox
  # implementation for untrusted work.
  class UnrestrictedSandbox < Sandbox
    # Configures a host sandbox with explicit read, write, and listing limits.
    # Filesystem writes remain disabled unless +writable+ is true.
    def initialize(workspace:, writable: false, max_read_bytes: 1_000_000, max_write_bytes: 1_000_000, max_list_entries: 10_000)
      super(workspace:)
      @writable = writable
      @max_read_bytes = Integer(max_read_bytes)
      @max_write_bytes = Integer(max_write_bytes)
      @max_list_entries = Integer(max_list_entries)
      unless [@max_read_bytes, @max_write_bytes, @max_list_entries].all?(&:positive?)
        raise ArgumentError, "sandbox limits must be positive"
      end

      @root = File.expand_path(workspace.root)
      capture_root_identity if File.exist?(@root)
    end

    # Opens the sandbox and verifies that the workspace root has not changed.
    def open(run: nil)
      if @root_identity
        validate_root!
      else
        @root = File.realpath(workspace.root)
        capture_root_identity
      end
      self
    end

    # Indicates whether this sandbox accepts filesystem mutations.
    def writable? = @writable

    # Reads a bounded UTF-8 file within the workspace.
    def read(path, context: nil)
      context&.check!
      File.open(existing_path(path), read_flags) do |file|
        raise ToolError, "Path is not a file" unless file.stat.file?

        content = file.read(@max_read_bytes + 1)
        raise ToolError, "File exceeds the read limit" if content.bytesize > @max_read_bytes

        content.force_encoding(Encoding::UTF_8)
        raise ToolError, "File is not valid UTF-8 text" unless content.valid_encoding?
        content
      end
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      raise ToolError, "File is not valid UTF-8 text"
    end

    # Produces a newline-delimited, sorted directory listing. Directories end in
    # +/+.
    def list(path = ".", context: nil)
      context&.check!
      directory = existing_path(path, allow_root: true)
      raise ToolError, "Path is not a directory" unless File.directory?(directory)

      entries = Dir.children(directory)
      raise ToolError, "Directory exceeds the listing limit" if entries.length > @max_list_entries

      entries.sort.map do |entry|
        File.lstat(File.join(directory, entry)).directory? ? "#{entry}/" : entry
      end.join("\n")
    end

    # Writes a bounded String without following a symbolic-link target.
    def write(path, content, context: nil)
      context&.check!
      raise ToolError, "Sandbox is read-only" unless writable?
      raise ToolError, "Content exceeds the write limit" if content.bytesize > @max_write_bytes

      flags = File::WRONLY | File::CREAT | File::TRUNC
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      flags |= File::NONBLOCK if defined?(File::NONBLOCK)
      File.open(writable_path(path), flags, 0o644) do |file|
        raise ToolError, "Path is not a file" unless file.stat.file?

        file.write(content)
      end
      "Wrote #{content.bytesize} bytes to #{display_path(path)}"
    rescue Errno::ELOOP
      raise ToolError, "Write target cannot be a symbolic link"
    end

    # Replaces exactly one occurrence of +old_text+ in a writable file.
    def replace(path, old_text, new_text, context: nil)
      context&.check!
      raise ToolError, "Text to replace cannot be empty" if old_text.empty?

      content = read(path, context:)
      occurrences = content.scan(old_text).length
      raise ToolError, "Text was not found in #{display_path(path)}" if occurrences.zero?
      raise ToolError, "Text occurs more than once in #{display_path(path)}" if occurrences > 1

      write(path, content.sub(old_text, new_text), context:)
    end

    # Executes an argument vector on the host from the workspace root.
    #
    # Shell syntax is not interpreted. The child starts with an empty environment
    # unless +inherit_environment+ is true, is terminated when the context is
    # cancelled or the timeout expires, and has each output stream truncated to
    # +max_output_bytes+.
    def execute_program(
      command,
      timeout:,
      context: nil,
      max_output_bytes: 1_000_000,
      environment: {},
      inherit_environment: false
    )
      argv = Array(command).map(&:to_s)
      raise ToolError, "Command must contain an executable" if argv.empty? || argv.first.empty?

      timeout = Float(timeout)
      max_output_bytes = Integer(max_output_bytes)
      raise ArgumentError, "timeout must be positive" unless timeout.positive?
      raise ArgumentError, "max_output_bytes must be positive" unless max_output_bytes.positive?

      stdout, stderr, status = capture(
        argv,
        timeout:,
        context:,
        max_output_bytes:,
        environment:,
        inherit_environment:
      )
      Sandbox::Execution.new(stdout:, stderr:, exit_code: status.exitstatus)
    end

    private

    def capture(argv, timeout:, context:, max_output_bytes:, environment:, inherit_environment:)
      result = nil
      deadline = monotonic_time + timeout
      Open3.popen3(
        environment.transform_keys(&:to_s).transform_values(&:to_s),
        *argv,
        chdir: workspace.root,
        pgroup: true,
        unsetenv_others: !inherit_environment
      ) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stdout_reader = Thread.new { drain(stdout, max_output_bytes) }
        stderr_reader = Thread.new { drain(stderr, max_output_bytes) }
        wait_for(wait_thread, [stdout_reader, stderr_reader], deadline, context)
        result = [stdout_reader.value, stderr_reader.value, wait_thread.value]
      ensure
        stdout_reader&.kill
        stderr_reader&.kill
      end
      result
    end

    def wait_for(wait_thread, readers, deadline, context)
      until !wait_thread.alive? && readers.none?(&:alive?)
        context&.check!
        raise ToolError, "Command timed out" if monotonic_time >= deadline

        wait_thread.join(0.01)
        Thread.pass
      end
    rescue
      terminate(wait_thread.pid)
      raise
    end

    def terminate(pid)
      Process.kill("TERM", -pid)
      deadline = monotonic_time + 0.5
      while monotonic_time < deadline
        return unless process_group_alive?(pid)

        Thread.pass
      end

      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def drain(io, max_output_bytes)
      captured = +""
      while (chunk = io.read(16_384))
        remaining = max_output_bytes + 1 - captured.bytesize
        captured << chunk.byteslice(0, remaining) if remaining.positive?
      end
      truncate(captured, max_output_bytes)
    end

    def truncate(output, max_output_bytes)
      return output if output.bytesize <= max_output_bytes

      "#{output.byteslice(0, max_output_bytes)}\n[output truncated]"
    end

    def existing_path(path, allow_root: false)
      candidate = expanded_path(path, allow_root:)
      validate_root!
      resolved = File.realpath(candidate)
      ensure_within_root!(resolved)
      resolved
    rescue Errno::ENOENT
      raise ToolError, "Path does not exist"
    end

    def writable_path(path)
      candidate = expanded_path(path)
      validate_root!
      raise ToolError, "Write target cannot be a symbolic link" if File.symlink?(candidate)

      if File.exist?(candidate)
        resolved = File.realpath(candidate)
        ensure_within_root!(resolved)
        resolved
      else
        parent = File.realpath(File.dirname(candidate))
        ensure_within_root!(parent)
        File.join(parent, File.basename(candidate))
      end
    rescue Errno::ENOENT
      raise ToolError, "Path does not exist"
    end

    def expanded_path(path, allow_root: false)
      components = path_components(path)
      raise ToolError, "Path must identify a workspace entry" if components.empty? && !allow_root

      File.join(@root, *components)
    end

    def ensure_within_root!(path)
      root_prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
      return path if path == @root || path.start_with?(root_prefix)

      raise ToolError, "Path escapes the configured workspace"
    end

    def validate_root!
      identity = File.stat(File.realpath(@root)).then { |stat| [stat.dev, stat.ino] }
      raise ToolError, "Workspace root changed after initialization" unless identity == @root_identity
    rescue Errno::ENOENT
      raise ToolError, "Workspace root changed after initialization"
    end

    def capture_root_identity
      @root = File.realpath(@root)
      @root_identity = File.stat(@root).then { |stat| [stat.dev, stat.ino] }.freeze
    end

    def read_flags
      flags = File::RDONLY
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      flags |= File::NONBLOCK if defined?(File::NONBLOCK)
      flags
    end

    def path_components(path)
      value = String(path)
      raise ToolError, "Path contains a null byte" if value.include?("\0")
      raise ToolError, "Path must be relative to the workspace" if value.start_with?(File::SEPARATOR)

      value.split(File::SEPARATOR).reject { |component| component.empty? || component == "." }.tap do |components|
        raise ToolError, "Path escapes the configured workspace" if components.include?("..")
      end
    end

    def display_path(path)
      path_components(path).join(File::SEPARATOR)
    end
  end
end
