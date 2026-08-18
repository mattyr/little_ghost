# frozen_string_literal: true

require "json"
require "securerandom"

module LittleGhost
  module CodeMode
    class Javascript::Session < LittleGhost::CodeMode::Session
      DEFAULT_YIELD_TIME_MS = 10_000
      MAX_EXEC_YIELD_TIME_MS = 30_000
      MAX_WAIT_YIELD_TIME_MS = 300_000
      DEFAULT_OUTPUT_TOKENS = 10_000
      MAX_OUTPUT_TOKENS = Javascript::Client::MAX_BUFFERED_OUTPUT_BYTES / 4
      MAX_PENDING_TOOL_CALLS = 1_024
      CLEANUP_TIMEOUT = 5

      ToolCall = Data.define(:cell_id, :call_id, :name, :arguments)
      ToolBatch = Data.define(:calls)
      def initialize(broker:, client:, sandbox: nil, workspace: nil, max_concurrency: 8)
        @broker = broker
        @client = client
        @sandbox = sandbox
        @workspace = workspace
        @max_concurrency = Integer(max_concurrency)
        raise ArgumentError, "max_concurrency must be positive" unless @max_concurrency.positive?
        @frames = {}
        @frames_mutex = Mutex.new
        @dispatch_counts = Hash.new(0)
        @terminating_cells = {}
        @fatal_errors = {}
        @discarded_cells = {}
        @dispatch_mutex = Mutex.new
        @dispatch_condition = ConditionVariable.new
        @queue = SizedQueue.new(MAX_PENDING_TOOL_CALLS)
        @closed = false
        @mutex = Mutex.new
        @worker = nil
      end

      def execute(source:, catalog:, frame: nil, yield_time_ms: DEFAULT_YIELD_TIME_MS,
        max_output_tokens: DEFAULT_OUTPUT_TOKENS, context: nil)
        ensure_open
        javascript_catalog = Javascript::Catalog.new(catalog)
        cell_id = SecureRandom.uuid
        @frames_mutex.synchronize do
          if @current_cell_id
            raise LittleGhost::ToolError, "Wait for or terminate the active JavaScript cell before starting another"
          end
          @frames[cell_id] = javascript_catalog
          @current_cell_id = cell_id
        end
        @client.start_cell(
          owner: self, dispatcher: self, source:, tools: javascript_catalog.host_definitions, cell_id:
        )
        observe(cell_id, yield_time_ms:, max_output_tokens:, context:)
      rescue
        if cell_id
          @frames_mutex.synchronize do
            @frames.delete(cell_id)
            @current_cell_id = nil if @current_cell_id == cell_id
          end
        end
        raise
      end

      def wait(yield_time_ms: DEFAULT_YIELD_TIME_MS, max_output_tokens: DEFAULT_OUTPUT_TOKENS,
        terminate: false, context: nil)
        ensure_open
        cell_id = @frames_mutex.synchronize { @current_cell_id }
        raise LittleGhost::ToolError, "There is no active JavaScript cell" unless cell_id
        result = if terminate
          terminate_cell(cell_id, max_output_tokens:)
        else
          @client.observe(
            owner: self, cell_id:, timeout: milliseconds(yield_time_ms),
            max_tokens: output_tokens(max_output_tokens), context:, resume: true
          )
        end
        finish(cell_id, result)
      rescue LittleGhost::CleanupError
        discard_failed_cell(cell_id)
        raise
      rescue LittleGhost::CancelledError, LittleGhost::DeadlineExceededError
        terminate_cell(cell_id, max_output_tokens:) if cell_id
        raise
      end

      def enqueue_tool_calls(cell_id:, calls:)
        if !calls.is_a?(Array) || calls.length > MAX_PENDING_TOOL_CALLS
          raise LittleGhost::ProtocolError, "Code-mode cell exceeded the pending tool-call limit"
        end
        batch = Array(calls).map do |call|
          raise LittleGhost::ProtocolError, "Code-mode host returned an invalid tool call" unless call.is_a?(Hash)

          ToolCall.new(
            cell_id:, call_id: call.fetch("call_id"), name: call.fetch("name"),
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

      def close
        cell_ids = begin_termination
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
          wait_for_dispatches(cell_ids)
          unless !worker || worker.join(CLEANUP_TIMEOUT)
            raise LittleGhost::CleanupError, "Code-mode dispatch worker cleanup timed out"
          end
        ensure
          @client.close
          @sandbox&.close
          @workspace&.close
          @frames_mutex.synchronize { @frames.clear }
          @current_cell_id = nil
        end
        raise_pending_failure!
      end

      def begin_client_termination(cell_id)
        begin_termination([cell_id])
      end

      def finish_client_termination(cell_id)
        wait_for_dispatches([cell_id])
      end

      def record_client_failure(cell_id, error)
        @dispatch_mutex.synchronize do
          return if @discarded_cells[cell_id]

          @fatal_errors[cell_id] ||= fatal_error(error)
        end
      end

      private

      def observe(cell_id, yield_time_ms:, max_output_tokens:, context:)
        result = @client.observe(
          owner: self, cell_id:, timeout: milliseconds(yield_time_ms),
          max_tokens: output_tokens(max_output_tokens), context:
        )
        finish(cell_id, result)
      rescue LittleGhost::CleanupError
        discard_failed_cell(cell_id)
        raise
      rescue LittleGhost::CancelledError, LittleGhost::DeadlineExceededError
        terminate_cell(cell_id) unless result
        raise
      end

      def finish(cell_id, result)
        status = result.fetch(:status)
        unless status == "yielded"
          @frames_mutex.synchronize do
            @frames.delete(cell_id)
            @current_cell_id = nil if @current_cell_id == cell_id
          end
        end
        raise_cell_failure!(cell_id) if status == "failed"
        raise LittleGhost::ToolError, result.fetch(:error, "Code-mode cell failed") if status == "failed"

        LittleGhost::CodeMode::CellResult.new(
          status: status.to_sym,
          output: result.fetch(:output, ""),
          error: result[:error]
        )
      end

      def discard_failed_cell(cell_id)
        @frames_mutex.synchronize do
          @frames.delete(cell_id)
          @current_cell_id = nil if @current_cell_id == cell_id
        end
        @dispatch_mutex.synchronize do
          @fatal_errors.delete(cell_id)
          @terminating_cells.delete(cell_id)
          @discarded_cells[cell_id] = true
        end
      end

      def ensure_worker
        return if @worker&.alive?

        @worker = Thread.new { dispatch }
        @worker.report_on_exception = false
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
          @frames_mutex.synchronize { @frames[call.cell_id] }
        end
        by_catalog.each do |catalog, calls|
          unless catalog
            calls.each { |call| reject(call, "Code-mode cell is no longer active") }
            next
          end

          valid, invalid = calls.partition do |call|
            call.arguments.is_a?(Hash) && catalog.key?(call.name)
          end
          invalid.each { |call| reject(call, "Unknown or invalid code-mode tool call: #{call.name}") }
          next if valid.empty?

          results = valid.each_slice(@max_concurrency).flat_map do |slice|
            threads = slice.map do |call|
              Thread.new do
                definition = catalog.fetch(call.name)
                @broker.call(
                  definition.fetch("canonical_name"), call.arguments,
                  id: "code-mode-#{call.cell_id}-#{call.call_id}"
                )
              end.tap { |thread| thread.report_on_exception = false }
            end
            threads.map(&:value)
          end
          valid.zip(results).each do |call, result|
            if result.error.nil?
              resolve(call, result.value)
            else
              reject(call, result.error)
            end
          end
        rescue => error
          calls.map(&:cell_id).uniq.each do |cell_id|
            record_client_failure(cell_id, error)
            @client.fail_cell(owner: self, cell_id:, error: fatal_error(error))
          rescue LittleGhost::CleanupError
            nil
          end
        ensure
          finish_dispatch(calls)
        end
      end

      def register_dispatch(calls)
        rejected = @dispatch_mutex.synchronize do
          calls.select { |call| @terminating_cells[call.cell_id] }.tap do |terminating|
            (calls - terminating).each { |call| @dispatch_counts[call.cell_id] += 1 }
          end
        end
        rejected.each { |call| reject(call, "Code-mode cell is terminating") }
        calls.reject! { |call| rejected.include?(call) }
      end

      def finish_dispatch(calls)
        @dispatch_mutex.synchronize do
          Array(calls).each do |call|
            @dispatch_counts[call.cell_id] -= 1
            @dispatch_counts.delete(call.cell_id) unless @dispatch_counts[call.cell_id].positive?
          end
          @dispatch_condition.broadcast
        end
      end

      def begin_termination(cell_ids = nil)
        ids = cell_ids || @frames_mutex.synchronize { @frames.keys }
        @dispatch_mutex.synchronize { ids.each { |cell_id| @terminating_cells[cell_id] = true } }
        ids
      end

      def wait_for_dispatches(cell_ids)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CLEANUP_TIMEOUT
        @dispatch_mutex.synchronize do
          while cell_ids.any? { |cell_id| @dispatch_counts[cell_id].positive? }
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise LittleGhost::CleanupError, "Code-mode nested tool cleanup timed out" unless remaining.positive?

            @dispatch_condition.wait(@dispatch_mutex, remaining)
          end
          cell_ids.each { |cell_id| @terminating_cells.delete(cell_id) }
        end
      end

      def terminate_cell(cell_id, max_output_tokens: DEFAULT_OUTPUT_TOKENS)
        begin_termination([cell_id])
        @client.terminate(owner: self, cell_id:, max_tokens: output_tokens(max_output_tokens))
      ensure
        wait_for_dispatches([cell_id])
      end

      def resolve(call, content)
        @client.complete_tool_call(
          cell_id: call.cell_id, call_id: call.call_id, ok: true, value: structured_content(content)
        )
      end

      def reject(call, message)
        @client.complete_tool_call(
          cell_id: call.cell_id, call_id: call.call_id, ok: false, error: String(message)
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
          calls.map(&:cell_id).uniq.each do |cell_id|
            record_client_failure(cell_id, error)
            @client.fail_cell(owner: self, cell_id:, error: fatal_error(error))
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
        end
      end

      def milliseconds(value)
        Float(value) / 1_000
      end

      def output_tokens(value)
        Integer(value).clamp(1, MAX_OUTPUT_TOKENS)
      end

      def raise_cell_failure!(cell_id)
        error = @dispatch_mutex.synchronize { @fatal_errors.delete(cell_id) }
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
