# frozen_string_literal: true

require "json"
require "securerandom"

module LittleGhost
  module CodeMode
    class Javascript::Session < LittleGhost::CodeMode::Session # :nodoc: all
      OBSERVATION_SECONDS = 60
      DEFAULT_OUTPUT_TOKENS = 10_000
      MAX_OUTPUT_TOKENS = Javascript::Client::MAX_BUFFERED_OUTPUT_BYTES / 4
      MAX_PENDING_TOOL_CALLS = 1_024
      CLEANUP_TIMEOUT = 5

      ToolCall = Data.define(:program_id, :call_id, :name, :arguments)
      ToolBatch = Data.define(:calls)
      Deadline = Struct.new(:task, :cancelled, :expiring, :finished, :error)

      def initialize(broker:, client:, sandbox: nil, workspace: nil, max_concurrency: 8,
        wall_seconds: 3_600, observation_seconds: OBSERVATION_SECONDS, cleanup_timeout: CLEANUP_TIMEOUT)
        @broker = broker
        @task_runner = broker.task_runner
        @client = client
        @sandbox = sandbox
        @workspace = workspace
        @max_concurrency = Integer(max_concurrency)
        raise ArgumentError, "max_concurrency must be positive" unless @max_concurrency.positive?
        @wall_seconds = Float(wall_seconds)
        @observation_seconds = Float(observation_seconds)
        @cleanup_timeout = Float(cleanup_timeout)
        raise ArgumentError, "wall_seconds must be positive" unless @wall_seconds.positive?
        raise ArgumentError, "observation_seconds must be positive" unless @observation_seconds.positive?
        raise ArgumentError, "cleanup_timeout must be positive" unless @cleanup_timeout.positive?
        @frames = {}
        @frames_mutex = Mutex.new
        @dispatch_counts = Hash.new(0)
        @terminating_programs = {}
        @fatal_errors = {}
        @discarded_programs = {}
        @dispatch_mutex = Mutex.new
        @dispatch_condition = ConditionVariable.new
        @queue = SizedQueue.new(MAX_PENDING_TOOL_CALLS)
        @closed = false
        @poisoned = false
        @control_mutex = Mutex.new
        @mutex = Mutex.new
        @worker = nil
        @deadline_mutex = Mutex.new
        @deadline_condition = ConditionVariable.new
        @deadlines = {}
        @pending_deadline_errors = []
      end

      def execute(source:, catalog:, frame: nil, max_output_tokens: DEFAULT_OUTPUT_TOKENS, context: nil)
        with_control do
          execute_program(source:, catalog:, frame:, max_output_tokens:, context:)
        end
      end

      def wait(max_output_tokens: DEFAULT_OUTPUT_TOKENS, context: nil)
        with_control { wait_for_program(max_output_tokens:, context:) }
      end

      def stop(max_output_tokens: DEFAULT_OUTPUT_TOKENS, context: nil)
        with_control { stop_program(max_output_tokens:, context:) }
      end

      def close
        cancel_all_deadlines
        program_ids = begin_termination
        already_closed, worker = @mutex.synchronize do
          if @closed
            [true, nil]
          else
            @closed = true
            drain_dispatch_queue
            @queue.push(:close, true)
            [false, @worker]
          end
        end
        return if already_closed

        begin
          @client.close_owner(self)
          wait_for_dispatches(program_ids)
          if worker
            begin
              worker.wait(deadline: Time.now + @cleanup_timeout)
            rescue LittleGhost::DeadlineExceededError
              raise LittleGhost::CleanupError, "Code-mode dispatch worker cleanup timed out"
            end
          end
        ensure
          @client.close
          @sandbox&.close
          @workspace&.close
          @frames_mutex.synchronize { @frames.clear }
          @current_program_id = nil
        end
        raise_pending_failure!
        raise_pending_deadline_error!
      end

      def begin_client_termination(program_id)
        begin_termination([program_id])
      end

      def finish_client_termination(program_id)
        wait_for_dispatches([program_id])
      end

      def record_client_failure(program_id, error)
        @dispatch_mutex.synchronize do
          return if @discarded_programs[program_id]

          @fatal_errors[program_id] ||= fatal_error(error)
        end
      end

      private

      def execute_program(source:, catalog:, frame:, max_output_tokens:, context:)
        ensure_open
        raise_pending_deadline_error!
        javascript_catalog = Javascript::Catalog.new(catalog)
        program_id = SecureRandom.uuid
        @frames_mutex.synchronize do
          if @current_program_id
            raise LittleGhost::ToolError, "Wait for or stop the active JavaScript program before starting another"
          end
          @frames[program_id] = javascript_catalog
          @current_program_id = program_id
        end
        ensure_worker if @task_runner.backend != :thread && Fiber.current_scheduler
        @client.start_program(
          owner: self, dispatcher: self, source:, tools: javascript_catalog.host_definitions, program_id:
        )
        start_deadline(program_id)
        observe(program_id, max_output_tokens:, context:)
      rescue
        cancel_deadline(program_id) if program_id
        if program_id
          @frames_mutex.synchronize do
            @frames.delete(program_id)
            @current_program_id = nil if @current_program_id == program_id
          end
        end
        raise
      end

      def wait_for_program(max_output_tokens:, context:)
        ensure_open
        program_id = @frames_mutex.synchronize { @current_program_id }
        raise_pending_deadline_error! unless program_id
        raise LittleGhost::ToolError, "There is no active JavaScript program" unless program_id
        result = @client.observe(
          owner: self, program_id:, timeout: @observation_seconds,
          max_tokens: output_tokens(max_output_tokens), context:
        )
        finish(program_id, result)
      rescue LittleGhost::CleanupError
        discard_failed_program(program_id)
        raise
      rescue LittleGhost::CancelledError, LittleGhost::DeadlineExceededError
        begin
          terminate_program(program_id, max_output_tokens:) if program_id
        ensure
          discard_failed_program(program_id) if program_id
        end
        raise
      end

      def stop_program(max_output_tokens:, context:)
        ensure_open
        context&.check!
        program_id = @frames_mutex.synchronize { @current_program_id }
        raise_pending_deadline_error! unless program_id
        raise LittleGhost::ToolError, "There is no active JavaScript program" unless program_id

        finish(program_id, terminate_program(program_id, max_output_tokens:))
      rescue LittleGhost::CleanupError
        discard_failed_program(program_id) if program_id
        raise
      end

      def enqueue_tool_calls(program_id:, calls:)
        if !calls.is_a?(Array) || calls.length > MAX_PENDING_TOOL_CALLS
          raise LittleGhost::ProtocolError, "Code-mode program exceeded the pending tool-call limit"
        end
        batch = Array(calls).map do |call|
          raise LittleGhost::ProtocolError, "Code-mode host returned an invalid tool call" unless call.is_a?(Hash)

          ToolCall.new(
            program_id:, call_id: call.fetch("call_id"), name: call.fetch("name"),
            arguments: call.fetch("arguments")
          )
        end
        @mutex.synchronize do
          raise LittleGhost::ToolError, "Code-mode session is closed" if @closed

          ensure_worker
          register_dispatch(batch)
          @queue.push(ToolBatch.new(calls: batch), true)
        end
      rescue ThreadError
        batch&.calls&.each { |call| reject(call, "Code-mode tool queue is full") }
        finish_dispatch(batch&.calls)
      rescue KeyError, TypeError
        raise LittleGhost::ProtocolError, "Code-mode host returned an invalid tool call"
      end
      public :enqueue_tool_calls

      def with_control
        acquired = @control_mutex.try_lock
        unless acquired
          raise LittleGhost::ToolError, "another code-mode control operation is already active"
        end

        yield
      ensure
        @control_mutex.unlock if acquired
      end

      def observe(program_id, max_output_tokens:, context:)
        result = @client.observe(
          owner: self, program_id:, timeout: @observation_seconds,
          max_tokens: output_tokens(max_output_tokens), context:
        )
        finish(program_id, result)
      rescue LittleGhost::CleanupError
        discard_failed_program(program_id)
        raise
      rescue LittleGhost::CancelledError, LittleGhost::DeadlineExceededError
        terminate_program(program_id) unless result
        raise
      end

      def finish(program_id, result)
        status = result.fetch(:status)
        unless status == "still_working"
          @frames_mutex.synchronize do
            @frames.delete(program_id)
            @current_program_id = nil if @current_program_id == program_id
          end
          cancel_deadline(program_id)
        end
        raise_program_failure!(program_id) if status == "failed"
        raise_deadline_error!(program_id)

        LittleGhost::CodeMode::ProgramResult.new(
          status: (status == "failed") ? :error : status.to_sym,
          output: result.fetch(:output, ""),
          error: result[:error]
        )
      end

      def discard_failed_program(program_id)
        @frames_mutex.synchronize do
          @frames.delete(program_id)
          @current_program_id = nil if @current_program_id == program_id
        end
        @dispatch_mutex.synchronize do
          @fatal_errors.delete(program_id)
          @terminating_programs.delete(program_id)
          @discarded_programs[program_id] = true
        end
        cancel_deadline(program_id)
      end

      def ensure_worker
        return if @worker&.alive?

        @worker = @task_runner.spawn { dispatch }
      end

      def drain_dispatch_queue
        loop do
          batch = @queue.pop(true)
          next if batch == :close

          finish_dispatch(batch.calls)
        rescue ThreadError
          break
        end
      end

      def dispatch
        loop do
          first = @queue.pop
          return if first == :close

          batches = [first]
          loop do
            value = @queue.pop(true)
            if value == :close
              @queue << :close
              break
            end
            batches << value
          rescue ThreadError
            break
          end
          dispatch_batch(batches.flat_map(&:calls))
        end
      rescue => error
        fail_queued(error)
      end

      def dispatch_batch(batch)
        by_catalog = batch.group_by do |call|
          @frames_mutex.synchronize { @frames[call.program_id] }
        end
        by_catalog.each do |catalog, calls|
          unless catalog
            calls.each { |call| reject(call, "Code-mode program is no longer active") }
            next
          end

          valid, invalid = calls.partition do |call|
            call.arguments.is_a?(Hash) && catalog.key?(call.name)
          end
          invalid.each { |call| reject(call, "Unknown or invalid code-mode tool call: #{call.name}") }
          next if valid.empty?

          results = Support::Executor.new(max_concurrency: @max_concurrency, task_runner: @task_runner).map(valid) do |call|
            definition = catalog.fetch(call.name)
            @broker.call(
              definition.fetch("canonical_name"), call.arguments,
              id: "code-mode-#{call.program_id}-#{call.call_id}"
            )
          end
          valid.zip(results).each do |call, result|
            if result.error.nil?
              resolve(call, result.value)
            else
              reject(call, result.error)
            end
          end
        rescue => error
          calls.map(&:program_id).uniq.each do |program_id|
            record_client_failure(program_id, error)
            @client.fail_program(owner: self, program_id:, error: fatal_error(error))
          rescue LittleGhost::CleanupError
            nil
          end
        ensure
          finish_dispatch(calls)
        end
      end

      def register_dispatch(calls)
        rejected = @dispatch_mutex.synchronize do
          calls.select { |call| @terminating_programs[call.program_id] }.tap do |terminating|
            (calls - terminating).each { |call| @dispatch_counts[call.program_id] += 1 }
          end
        end
        rejected.each { |call| reject(call, "Code-mode program is terminating") }
        calls.reject! { |call| rejected.include?(call) }
      end

      def finish_dispatch(calls)
        @dispatch_mutex.synchronize do
          Array(calls).each do |call|
            @dispatch_counts[call.program_id] -= 1
            @dispatch_counts.delete(call.program_id) unless @dispatch_counts[call.program_id].positive?
          end
          @dispatch_condition.broadcast
        end
      end

      def begin_termination(program_ids = nil)
        ids = program_ids || @frames_mutex.synchronize { @frames.keys }
        @dispatch_mutex.synchronize { ids.each { |program_id| @terminating_programs[program_id] = true } }
        ids
      end

      def wait_for_dispatches(program_ids)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @cleanup_timeout
        timed_out = false
        @dispatch_mutex.synchronize do
          while program_ids.any? { |program_id| @dispatch_counts[program_id].positive? }
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            unless remaining.positive?
              timed_out = true
              break
            end

            @dispatch_condition.wait(@dispatch_mutex, remaining)
          end
          program_ids.each { |program_id| @terminating_programs.delete(program_id) } unless timed_out
        end
        return unless timed_out

        @mutex.synchronize { @poisoned = true }
        raise LittleGhost::CleanupError, "Code-mode nested tool cleanup timed out"
      end

      def terminate_program(program_id, max_output_tokens: DEFAULT_OUTPUT_TOKENS)
        begin_termination([program_id])
        @client.terminate(owner: self, program_id:, max_tokens: output_tokens(max_output_tokens))
      ensure
        wait_for_dispatches([program_id])
      end

      def resolve(call, content)
        @client.complete_tool_call(
          program_id: call.program_id, call_id: call.call_id, ok: true, value: structured_content(content)
        )
      end

      def reject(call, message)
        @client.complete_tool_call(
          program_id: call.program_id, call_id: call.call_id, ok: false, error: String(message)
        )
      end

      def structured_content(content)
        value = JSON.parse(content)
        (value.is_a?(Hash) || value.is_a?(Array)) ? value : content
      rescue JSON::ParserError, TypeError
        content
      end

      def fail_queued(error)
        loop do
          batch = @queue.pop(true)
          next if batch == :close

          calls = batch.calls
          calls.map(&:program_id).uniq.each do |program_id|
            record_client_failure(program_id, error)
            @client.fail_program(owner: self, program_id:, error: fatal_error(error))
          rescue LittleGhost::CleanupError
            nil
          end
          finish_dispatch(calls)
        rescue ThreadError
          break
        end
      end

      def ensure_open
        @mutex.synchronize do
          raise LittleGhost::ToolError, "Code-mode session is closed" if @closed
          raise LittleGhost::ToolError, "Code-mode session cannot be reused after cleanup failed" if @poisoned
        end
      end

      def output_tokens(value)
        Integer(value).clamp(1, MAX_OUTPUT_TOKENS)
      end

      def start_deadline(program_id)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @wall_seconds
        state = Deadline.new(nil, false, false, false, nil)
        @deadline_mutex.synchronize do
          @deadlines[program_id] = state
          state.task = @task_runner.spawn do
            expired = @deadline_mutex.synchronize do
              loop do
                break false if state.cancelled

                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                break true unless remaining.positive?

                @deadline_condition.wait(@deadline_mutex, remaining)
              end
            end
            expire_program(program_id, state) if expired
          rescue => error
            finish_deadline(program_id, state, error)
          end
        end
      end

      def expire_program(program_id, state)
        current = @deadline_mutex.synchronize do
          next false unless @deadlines[program_id].equal?(state) && !state.cancelled

          state.expiring = true
          true
        end
        return unless current

        error = LittleGhost::ToolError.new("code-mode program timed out")
        begin
          terminate_program(program_id)
        rescue => cleanup_error
          error = cleanup_error
        ensure
          @frames_mutex.synchronize do
            @frames.delete(program_id)
            @current_program_id = nil if @current_program_id == program_id
          end
          finish_deadline(program_id, state, error)
        end
      end

      def finish_deadline(program_id, state, error)
        @deadline_mutex.synchronize do
          return unless @deadlines[program_id].equal?(state)

          state.error = error
          state.finished = true
          @pending_deadline_errors << [program_id, error]
          @deadline_condition.broadcast
        end
      end

      def cancel_deadline(program_id)
        task = @deadline_mutex.synchronize do
          state = @deadlines[program_id]
          return unless state

          if state.expiring
            @deadline_condition.wait(@deadline_mutex) until state.finished
          else
            state.cancelled = true
            @deadline_condition.broadcast
          end
          @deadlines.delete(program_id)
          state.task
        end
        task&.wait unless task&.current?
      end

      def cancel_all_deadlines
        program_ids = @deadline_mutex.synchronize { @deadlines.keys }
        program_ids.each { |program_id| cancel_deadline(program_id) }
      end

      def raise_deadline_error!(program_id)
        error = @deadline_mutex.synchronize do
          state = @deadlines[program_id]
          @deadline_condition.wait(@deadline_mutex) while state&.expiring && !state.finished
          pair = @pending_deadline_errors.find { |candidate| candidate.first == program_id }
          @pending_deadline_errors.delete(pair)&.last
        end
        raise error if error
      end

      def raise_pending_deadline_error!
        error, task = @deadline_mutex.synchronize do
          pair = @pending_deadline_errors.shift
          state = @deadlines.delete(pair&.first)
          [pair&.last, state&.task]
        end
        task&.wait unless task&.current?
        raise error if error
      end

      def raise_program_failure!(program_id)
        error = @dispatch_mutex.synchronize { @fatal_errors.delete(program_id) }
        raise error if error
      end

      def raise_pending_failure!
        error = @dispatch_mutex.synchronize do
          value = @fatal_errors.values.first
          @fatal_errors.clear
          value
        end
        raise error if error
      end

      def fatal_error(error)
        routine_errors = [
          LittleGhost::CancelledError,
          LittleGhost::DeadlineExceededError,
          LittleGhost::CleanupError
        ]
        return error if routine_errors.any? { |error_class| error.is_a?(error_class) }

        LittleGhost::CleanupError.new("Code-mode nested tool dispatch failed: #{error.message}")
      end
    end
  end
end
