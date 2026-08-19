# frozen_string_literal: true

require "securerandom"

module LittleGhost
  module CodeMode
    class Javascript::Client
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

      class Cell
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
            (@terminal || {status: "still_working"}).merge(cell_id: id, output:)
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
            @terminal.merge(cell_id: id, output: drain_output)
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

        @cells = {}
        @cells_mutex = Mutex.new
        @process_mutex = Mutex.new
        @writer_mutex = Mutex.new
        @closed = false
        @failure = nil
      end

      def start_cell(owner:, dispatcher:, source:, tools:, cell_id: SecureRandom.uuid)
        cell = nil
        send_message({type: "execute", cell_id:, source:, tools:}) do |generation|
          cell = Cell.new(id: cell_id, owner:, dispatcher:, generation:)
          @cells_mutex.synchronize do
            raise LittleGhost::ToolError, "Code-mode client is closed" if @closed

            @cells[cell.id] = cell
          end
        end
        cell.id
      rescue
        @cells_mutex.synchronize { @cells.delete(cell&.id) }
        raise
      end

      def observe(owner:, cell_id:, timeout:, max_tokens:, context: nil)
        cell = owned_cell(owner, cell_id)
        result = cell.observe(timeout:, max_tokens:, context:)
        release_cell(cell) if cell.terminal?
        result
      end

      def terminate(owner:, cell_id:, max_tokens: 10_000)
        cell = owned_cell(owner, cell_id)
        send_message({type: "terminate", cell_id: cell.id}, cell:) unless cell.terminal?
        result = cell.observe(timeout: TERMINATION_TIMEOUT, max_tokens:)
        unless cell.terminal?
          process_failed(
            RuntimeError.new("Code-mode host did not acknowledge termination"),
            generation: cell.generation
          )
          result = cell.wait_until_terminal(timeout: TERMINATION_TIMEOUT + Javascript::Session::CLEANUP_TIMEOUT)
        end
        release_cell(cell)
        result
      end

      def close_owner(owner)
        cells = @cells_mutex.synchronize { @cells.values.select { |cell| cell.owner.equal?(owner) } }
        cells.each do |cell|
          terminate(owner:, cell_id: cell.id)
        rescue LittleGhost::Error, IOError, SystemCallError
          release_cell(cell)
        end
      end

      def complete_tool_call(cell_id:, call_id:, ok:, value: nil, error: nil)
        cell = @cells_mutex.synchronize { @cells[cell_id.to_s] }
        return unless cell

        send_message(
          {type: "tool_result", cell_id:, call_id:, ok:, value:, error:},
          cell:
        )
      end

      def fail_cell(owner:, cell_id:, error:)
        cell = owned_cell(owner, cell_id)
        request_cell_failure(cell, error.message)
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
        fail_all_cells("Code-mode client closed")
        stop_process(process)
      end

      private

      def owned_cell(owner, cell_id)
        @cells_mutex.synchronize do
          cell = @cells[cell_id.to_s]
          unless cell && cell.owner.equal?(owner)
            raise LittleGhost::ToolError, "Unknown code-mode program: #{cell_id}"
          end

          cell
        end
      end

      def release_cell(cell)
        @cells_mutex.synchronize { @cells.delete(cell.id) if @cells[cell.id].equal?(cell) }
      end

      def send_message(message, cell: nil)
        return false if cell&.terminal?

        generation = nil
        @writer_mutex.synchronize do
          ensure_started
          generation, input = @process_mutex.synchronize { [@generation, @input] }
          raise(@failure || LittleGhost::CleanupError.new("Code-mode host is unavailable")) unless input
          return false if cell&.terminal?
          if cell && !generation.equal?(cell.generation)
            raise LittleGhost::CleanupError, "Code-mode program belongs to an inactive host"
          end

          yield generation if block_given?
          Protocol.write(input, message)
        end
      rescue Protocol::Error, IOError, SystemCallError => error
        process_failed(error, generation:) if generation
        return false if cell&.terminal?

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
          cells = @process_mutex.synchronize do
            claimed = claim_active_cells(generation, failure)
            @failure ||= failure unless claimed.empty?
            clear_process_state
            claimed
          end
          unless cells.empty?
            finish_process_failure(process, cells, failure)
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
        cell_id = message["cell_id"].to_s
        cell = @cells_mutex.synchronize { @cells[cell_id] }
        return unless cell

        case message["type"]
        when "output"
          request_cell_failure(cell, "Code-mode output exceeded the buffer limit") if cell.output(message["value"])
        when "complete"
          cell.complete(status: "completed")
        when "terminated"
          begin
            cell.dispatcher.finish_client_termination(cell.id) if cell.client_termination_requested?
            cell.terminated
          rescue => error
            cell.dispatcher.record_client_failure(cell.id, error)
            cell.complete(status: "failed", error: error.message)
          end
        when "failed"
          if message["fatal"]
            cell.dispatcher.record_client_failure(cell.id, cleanup_error(message["error"].to_s))
          end
          cell.complete(status: "failed", error: message["error"].to_s)
        when "tool_calls"
          cell.dispatcher.enqueue_tool_calls(cell_id:, calls: message.fetch("calls"))
        else
          request_cell_failure(cell, "Code-mode host returned an unknown message")
        end
      rescue LittleGhost::ProtocolError, KeyError, TypeError => error
        request_cell_failure(cell, "Code-mode host returned an invalid message: #{error.message}") if cell
      end

      def request_cell_failure(cell, error)
        failure = cleanup_error(error)
        cell.dispatcher.record_client_failure(cell.id, failure)
        return unless cell.request_client_termination(failure.message)

        cell.dispatcher.begin_client_termination(cell.id)
        send_message({type: "terminate", cell_id: cell.id}, cell:)
      end

      def process_failed(error, generation:)
        process, cells, failure = @writer_mutex.synchronize do
          current = @process_mutex.synchronize do
            return if @closed || @failure || !@generation.equal?(generation)

            process_state
          end
          return unless current.compact.any?

          wait_for_reader(current)
          @process_mutex.synchronize do
            return if @closed || @failure || !@generation.equal?(generation)

            failure = process_failure(error, current)
            cells = claim_active_cells(generation, failure)
            @failure = failure unless cells.empty?
            clear_process_state
            [current, cells, failure]
          end
        end
        finish_process_failure(process, cells, failure)
      end

      def finish_process_failure(process, cells, failure)
        if cells.empty?
          stop_process(process)
          warn("little_ghost_code_mode_host_exited error=#{failure.message.inspect}")
          return
        end
        cells.each { |cell| cell.dispatcher.record_client_failure(cell.id, failure) }
        cells.each { |cell| cell.dispatcher.begin_client_termination(cell.id) }
        stop_process(process)
        Thread.new do
          cells.each do |cell|
            cell.dispatcher.finish_client_termination(cell.id)
          rescue => error
            cell.dispatcher.record_client_failure(cell.id, error)
          ensure
            cell.complete(status: "failed", error: failure.message)
          end
        end.report_on_exception = false
      end

      def claim_active_cells(generation, failure)
        return [] unless generation

        cells = @cells_mutex.synchronize { @cells.values.select { |cell| cell.generation.equal?(generation) } }
        cells.select { |cell| cell.claim_client_failure(failure.message) }
      end

      def fail_all_cells(message)
        cells = @cells_mutex.synchronize { @cells.values.dup }
        cells.each { |cell| cell.dispatcher.begin_client_termination(cell.id) }
        cells.each do |cell|
          cell.dispatcher.finish_client_termination(cell.id)
        rescue => error
          cell.dispatcher.record_client_failure(cell.id, error)
        ensure
          cell.complete(status: "failed", error: message)
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
