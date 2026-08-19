# frozen_string_literal: true

require "securerandom"

module LittleGhost
  module CodeMode
    class Javascript::Client # :nodoc: all
      MAX_BUFFERED_OUTPUT_BYTES = 4 * 1024 * 1024
      MAX_CAPTURED_STDERR_BYTES = 64 * 1024
      SHUTDOWN_TIMEOUT = 0.5
      TERMINATION_TIMEOUT = 1.0

      class StderrCapture
        def initialize
          @bytes = 0
          @truncated = false
          @mutex = Mutex.new
        end

        def append(chunk)
          @mutex.synchronize do
            remaining = MAX_CAPTURED_STDERR_BYTES - @bytes
            @bytes += [chunk.bytesize, remaining].min if remaining.positive?
            @truncated = true if chunk.bytesize > remaining
          end
        end

        def diagnostic
          @mutex.synchronize do
            return if @bytes.zero?

            @truncated ? "stderr_bytes>=#{@bytes}" : "stderr_bytes=#{@bytes}"
          end
        end
      end
      private_constant :StderrCapture

      class Program
        attr_reader :id, :owner, :dispatcher, :generation

        def initialize(id:, owner:, dispatcher:, generation: nil)
          @id = id
          @owner = owner
          @dispatcher = dispatcher
          @generation = generation
          @outputs = []
          @output_bytes = 0
          @returned_output = false
          @terminal = nil
          @termination_error = nil
          @client_termination_requested = false
          @mutex = Mutex.new
          @condition = ConditionVariable.new
        end

        def output(value)
          text = String(value)
          @mutex.synchronize do
            return if @terminal || @termination_error

            if @output_bytes + text.bytesize > MAX_BUFFERED_OUTPUT_BYTES
              @termination_error = "Code-mode output exceeded the buffer limit"
              overflow = true
            else
              @outputs << text
              @output_bytes += text.bytesize
            end
            @condition.broadcast
            overflow
          end
        end

        def complete(status:, error: nil)
          @mutex.synchronize do
            return if @terminal

            if status == "completed" && @termination_error
              status = "failed"
              error = @termination_error
            end
            @terminal = {status:, error:}.compact
            @condition.broadcast
          end
        end

        def terminated
          complete(
            status: @termination_error ? "failed" : "terminated",
            error: @termination_error
          )
        end

        def request_client_termination(error)
          @mutex.synchronize do
            return false if @terminal || @client_termination_requested

            @client_termination_requested = true
            @termination_error = error
            true
          end
        end

        def claim_client_failure(error)
          @mutex.synchronize do
            return false if @terminal

            @client_termination_requested = true
            @termination_error = error
            true
          end
        end

        def client_termination_requested?
          @mutex.synchronize { @client_termination_requested }
        end

        def observe(timeout:, max_tokens:, context: nil)
          deadline = monotonic + timeout
          @mutex.synchronize do
            loop do
              context&.check!
              break if @terminal || monotonic >= deadline

              @condition.wait(@mutex, [deadline - monotonic, 0.05].min)
            end
            output = drain_output
            output = LittleGhost::Support::OutputTruncation
              .truncate_middle_with_token_budget(output, max_tokens).first
            (@terminal || {status: "still_working"}).merge(program_id: id, output:)
          end
        end

        def wait_until_terminal(timeout: nil)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(timeout) if timeout
          @mutex.synchronize do
            until @terminal
              remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if remaining && !remaining.positive?
                raise LittleGhost::CleanupError, "Code-mode program cleanup timed out"
              end

              @condition.wait(@mutex, remaining)
            end
            @terminal.merge(program_id: id, output: drain_output)
          end
        end

        def terminal?
          @mutex.synchronize { !@terminal.nil? }
        end

        private

        def drain_output
          had_output = !@outputs.empty?
          output = @outputs.join("\n")
          @outputs.clear
          @output_bytes = 0
          if !had_output
            output
          elsif @returned_output
            "\n#{output}"
          else
            @returned_output = true
            output
          end
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      def initialize(session_factory:)
        unless session_factory.respond_to?(:call)
          raise ArgumentError, "Code-mode process-session factory must be callable"
        end
        @session_factory = session_factory

        @programs = {}
        @programs_mutex = Mutex.new
        @process_mutex = Mutex.new
        @writer_mutex = Mutex.new
        @closed = false
        @failure = nil
      end

      def start_program(owner:, dispatcher:, source:, tools:, program_id: SecureRandom.uuid)
        program = nil
        send_message({type: "execute", program_id:, source:, tools:}) do |generation|
          program = Program.new(id: program_id, owner:, dispatcher:, generation:)
          @programs_mutex.synchronize do
            raise LittleGhost::ToolError, "Code-mode client is closed" if @closed

            @programs[program.id] = program
          end
        end
        program.id
      rescue
        @programs_mutex.synchronize { @programs.delete(program&.id) }
        raise
      end

      def observe(owner:, program_id:, timeout:, max_tokens:, context: nil)
        program = owned_program(owner, program_id)
        result = program.observe(timeout:, max_tokens:, context:)
        release_program(program) if program.terminal?
        result
      end

      def terminate(owner:, program_id:, max_tokens: 10_000)
        program = owned_program(owner, program_id)
        send_message({type: "terminate", program_id: program.id}, program:) unless program.terminal?
        result = program.observe(timeout: TERMINATION_TIMEOUT, max_tokens:)
        unless program.terminal?
          process_failed(
            RuntimeError.new("Code-mode host did not acknowledge termination"),
            generation: program.generation
          )
          result = program.wait_until_terminal(timeout: TERMINATION_TIMEOUT + Javascript::Session::CLEANUP_TIMEOUT)
        end
        release_program(program)
        result
      end

      def close_owner(owner)
        programs = @programs_mutex.synchronize { @programs.values.select { |program| program.owner.equal?(owner) } }
        programs.each do |program|
          terminate(owner:, program_id: program.id)
        rescue LittleGhost::Error, IOError, SystemCallError
          release_program(program)
        end
      end

      def complete_tool_call(program_id:, call_id:, ok:, value: nil, error: nil)
        program = @programs_mutex.synchronize { @programs[program_id.to_s] }
        return unless program

        send_message(
          {type: "tool_result", program_id:, call_id:, ok:, value:, error:},
          program:
        )
      end

      def fail_program(owner:, program_id:, error:)
        program = owned_program(owner, program_id)
        request_program_failure(program, error.message)
      end

      def close
        process = @writer_mutex.synchronize do
          @process_mutex.synchronize do
            return if @closed

            @closed = true
            current = process_state
            clear_process_state
            current
          end
        end
        fail_all_programs("Code-mode client closed")
        stop_process(process)
      end

      private

      def owned_program(owner, program_id)
        @programs_mutex.synchronize do
          program = @programs[program_id.to_s]
          unless program && program.owner.equal?(owner)
            raise LittleGhost::ToolError, "Unknown code-mode program: #{program_id}"
          end

          program
        end
      end

      def release_program(program)
        @programs_mutex.synchronize { @programs.delete(program.id) if @programs[program.id].equal?(program) }
      end

      def send_message(message, program: nil)
        return false if program&.terminal?

        generation = nil
        @writer_mutex.synchronize do
          ensure_started
          generation, input = @process_mutex.synchronize { [@generation, @input] }
          raise(@failure || LittleGhost::CleanupError.new("Code-mode host is unavailable")) unless input
          return false if program&.terminal?
          if program && !generation.equal?(program.generation)
            raise LittleGhost::CleanupError, "Code-mode program belongs to an inactive host"
          end

          yield generation if block_given?
          Protocol.write(input, message)
        end
      rescue Protocol::Error, IOError, SystemCallError => error
        process_failed(error, generation:) if generation
        return false if program&.terminal?

        raise(@failure || cleanup_error(error))
      end

      def ensure_started
        process, generation = @process_mutex.synchronize do
          raise LittleGhost::ToolError, "Code-mode client is closed" if @closed
          raise @failure if @failure
          return if @wait_thread&.alive? && @reader_thread&.alive?

          [process_state, @generation]
        end
        if process.compact.any?
          wait_for_reader(process)
          failure = process_failure(EOFError.new("Code-mode host was not running"), process)
          programs = @process_mutex.synchronize do
            claimed = claim_active_programs(generation, failure)
            @failure ||= failure unless claimed.empty?
            clear_process_state
            claimed
          end
          unless programs.empty?
            finish_process_failure(process, programs, failure)
            raise failure
          end

          stop_process(process)
          warn("little_ghost_code_mode_host_exited error=#{failure.message.inspect}")
        end

        @process_mutex.synchronize do
          raise LittleGhost::ToolError, "Code-mode client is closed" if @closed
          raise @failure if @failure
          clear_process_state

          @input = @session_factory.call
          unless @input.respond_to?(:write) && @input.respond_to?(:read) && @input.respond_to?(:close)
            raise LittleGhost::ConfigurationError, "Code-mode process-session factory returned an invalid session"
          end
          @output = @input
          @wait_thread = @input
          generation = @generation = Object.new
          @stderr_capture = StderrCapture.new
          @reader_thread = Thread.new { read_messages(@output, generation, @stderr_capture) }
          @reader_thread.report_on_exception = false
        end
      rescue LittleGhost::CleanupError
        raise
      rescue => error
        failure = cleanup_error(error, "Code-mode host could not start")
        @process_mutex.synchronize { @failure ||= failure }
        raise failure
      end

      def read_messages(session, generation, capture)
        buffer = +"".b
        loop do
          chunk = session.read(timeout: 0.05)
          capture.append(chunk.stderr) unless chunk.stderr.empty?
          buffer << chunk.stdout
          while (message = Protocol.extract!(buffer))
            receive(message)
          end
          break if chunk.eof
        end
        raise Protocol::Error, "Code-mode host ended with an incomplete frame" unless buffer.empty?
        process_failed(EOFError.new("Code-mode host closed its output"), generation:)
      rescue => error
        process_failed(error, generation:)
      end

      def receive(message)
        program_id = message["program_id"].to_s
        program = @programs_mutex.synchronize { @programs[program_id] }
        return unless program

        case message["type"]
        when "output"
          request_program_failure(program, "Code-mode output exceeded the buffer limit") if program.output(message["value"])
        when "complete"
          program.complete(status: "completed")
        when "terminated"
          begin
            program.dispatcher.finish_client_termination(program.id) if program.client_termination_requested?
            program.terminated
          rescue => error
            program.dispatcher.record_client_failure(program.id, error)
            program.complete(status: "failed", error: error.message)
          end
        when "failed"
          if message["fatal"]
            program.dispatcher.record_client_failure(program.id, cleanup_error(message["error"].to_s))
          end
          program.complete(status: "failed", error: message["error"].to_s)
        when "tool_calls"
          program.dispatcher.enqueue_tool_calls(program_id:, calls: message.fetch("calls"))
        else
          request_program_failure(program, "Code-mode host returned an unknown message")
        end
      rescue LittleGhost::ProtocolError, KeyError, TypeError => error
        request_program_failure(program, "Code-mode host returned an invalid message: #{error.message}") if program
      end

      def request_program_failure(program, error)
        failure = cleanup_error(error)
        program.dispatcher.record_client_failure(program.id, failure)
        return unless program.request_client_termination(failure.message)

        program.dispatcher.begin_client_termination(program.id)
        send_message({type: "terminate", program_id: program.id}, program:)
      end

      def process_failed(error, generation:)
        process, programs, failure = @writer_mutex.synchronize do
          current = @process_mutex.synchronize do
            return if @closed || @failure || !@generation.equal?(generation)

            process_state
          end
          return unless current.compact.any?

          wait_for_reader(current)
          @process_mutex.synchronize do
            return if @closed || @failure || !@generation.equal?(generation)

            failure = process_failure(error, current)
            programs = claim_active_programs(generation, failure)
            @failure = failure unless programs.empty?
            clear_process_state
            [current, programs, failure]
          end
        end
        finish_process_failure(process, programs, failure)
      end

      def finish_process_failure(process, programs, failure)
        if programs.empty?
          stop_process(process)
          warn("little_ghost_code_mode_host_exited error=#{failure.message.inspect}")
          return
        end
        programs.each { |program| program.dispatcher.record_client_failure(program.id, failure) }
        programs.each { |program| program.dispatcher.begin_client_termination(program.id) }
        stop_process(process)
        Thread.new do
          programs.each do |program|
            program.dispatcher.finish_client_termination(program.id)
          rescue => error
            program.dispatcher.record_client_failure(program.id, error)
          ensure
            program.complete(status: "failed", error: failure.message)
          end
        end.report_on_exception = false
      end

      def claim_active_programs(generation, failure)
        return [] unless generation

        programs = @programs_mutex.synchronize { @programs.values.select { |program| program.generation.equal?(generation) } }
        programs.select { |program| program.claim_client_failure(failure.message) }
      end

      def fail_all_programs(message)
        programs = @programs_mutex.synchronize { @programs.values.dup }
        programs.each { |program| program.dispatcher.begin_client_termination(program.id) }
        programs.each do |program|
          program.dispatcher.finish_client_termination(program.id)
        rescue => error
          program.dispatcher.record_client_failure(program.id, error)
        ensure
          program.complete(status: "failed", error: message)
        end
      end

      def process_state
        [@input, @output, @error, @wait_thread, @reader_thread, @stderr_thread, @stderr_capture, @generation]
      end

      def clear_process_state
        @input = @output = @error = @wait_thread = @reader_thread = @stderr_thread = @stderr_capture = nil
        @generation = nil
      end

      def stop_process(process)
        return unless process

        input, _output, _error, _session, reader_thread, _stderr_thread, _stderr_capture, _generation = process
        input&.close
        reader_thread&.join(SHUTDOWN_TIMEOUT) unless reader_thread.equal?(Thread.current)
      rescue IOError
        nil
      end

      def process_failure(error, process)
        _input, _output, _error, session, _reader_thread, _stderr_thread, capture, _generation = process
        status = session&.wait(timeout: 0, terminate: false) unless session&.alive?
        details = [process_failure_reason(error)]
        details << process_status(status) if status
        details << capture.diagnostic if capture&.diagnostic
        cleanup_error(details.compact.join("; "), "Code-mode host failed")
      rescue => diagnostic_error
        cleanup_error(
          "#{process_failure_reason(error)}; diagnostics=#{diagnostic_error.class}",
          "Code-mode host failed"
        )
      end

      def wait_for_reader(process)
        reader_thread = process[4]
        reader_thread&.join(SHUTDOWN_TIMEOUT) unless reader_thread.equal?(Thread.current)
      end

      def process_failure_reason(error)
        case error
        when EOFError
          "output_closed"
        when Protocol::Error
          "invalid_protocol"
        when SystemCallError
          "#{error.class}(errno=#{error.errno})"
        when IOError
          error.class.to_s
        else
          error.is_a?(Exception) ? error.message : error.to_s
        end
      end

      def process_status(status)
        return "exit_status=#{status.exitstatus}" if status.exited?
        return "signal=SIG#{Signal.signame(status.termsig)}" if status.signaled?

        "process_status=#{status.to_i}"
      rescue ArgumentError
        "signal=#{status.termsig}"
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def cleanup_error(error, prefix = nil)
        return error if error.is_a?(LittleGhost::CleanupError)

        detail = error.is_a?(Exception) ? error.message : error.to_s
        message = [prefix, detail].compact.join(": ")
        LittleGhost::CleanupError.new(message)
      end
    end
  end
end
