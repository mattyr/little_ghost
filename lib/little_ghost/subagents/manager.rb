# frozen_string_literal: true

require "securerandom"
require_relative "definition"

module LittleGhost
  module Subagents
    class Manager
      class CleanupError < LittleGhost::CleanupError; end

      DEFAULT_MAX_CONCURRENT = 8
      DEFAULT_MAX_IDENTITIES = 20
      DEFAULT_MAX_TURNS = 100
      DEFAULT_MAX_QUEUED_TURNS_PER_IDENTITY = 8
      DEFAULT_MAX_MESSAGE_CHARS = 50_000
      DEFAULT_MAX_RESPONSE_CHARS = 100_000
      DEFAULT_WAIT_TIMEOUT = 20.0
      DEFAULT_CLOSE_TIMEOUT = 5.0
      MAX_PROGRESS_CHARS = 160
      MAX_PROGRESS_SOURCE_CHARS = 4_096
      PROGRESS_SEPARATOR = /[\p{Z}\p{Cc}\p{Cf}]/
      CANCELLATION_POLL_INTERVAL = 0.05

      Turn = Struct.new(:number, :message, :completion, :operation_id, :parent_operation_id)
      Identity = Struct.new(
        :subagent_id,
        :definition,
        :agent,
        :history,
        :state,
        :queue,
        :worker,
        :status,
        :next_turn,
        :current_turn,
        :current,
        :latest_turn,
        :latest_response,
        :latest_response_truncated,
        :latest_error,
        :progress_message,
        :progress_sequence
      )

      class Completion
        def initialize
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @resolved = false
        end

        def resolve(value)
          @mutex.synchronize do
            return if @resolved

            @value = value
            @resolved = true
            @condition.broadcast
          end
        end

        def reject(error)
          @mutex.synchronize do
            return if @resolved

            @error = error
            @resolved = true
            @condition.broadcast
          end
        end

        def value(cancellation_token: nil, deadline: nil)
          @mutex.synchronize do
            until @resolved
              cancellation_token&.raise_if_cancelled!
              if deadline && Time.now >= deadline
                raise DeadlineExceededError, "The run deadline was reached"
              end

              timeout = deadline ? [deadline - Time.now, 0.05].min : 0.05
              @condition.wait(@mutex, [timeout, 0].max)
            end
            raise @error if @error

            @value
          end
        end
      end

      class Capacity
        def initialize(limit)
          @available = limit
          @mutex = Mutex.new
          @condition = ConditionVariable.new
        end

        def synchronize(cancellation_token, deadline: nil)
          @mutex.synchronize do
            while @available.zero?
              cancellation_token.raise_if_cancelled!
              if deadline && Time.now >= deadline
                raise DeadlineExceededError, "The run deadline was reached"
              end

              timeout = deadline ? [deadline - Time.now, 0.05].min : 0.05
              @condition.wait(@mutex, [timeout, 0].max)
            end
            @available -= 1
          end

          begin
            yield
          ensure
            @mutex.synchronize do
              @available += 1
              @condition.signal
            end
          end
          true
        end
      end

      attr_reader :definitions

      def initialize(
        definitions,
        max_concurrent: DEFAULT_MAX_CONCURRENT,
        max_identities: DEFAULT_MAX_IDENTITIES,
        max_turns: DEFAULT_MAX_TURNS,
        max_queued_turns_per_identity: DEFAULT_MAX_QUEUED_TURNS_PER_IDENTITY,
        max_message_chars: DEFAULT_MAX_MESSAGE_CHARS,
        max_response_chars: DEFAULT_MAX_RESPONSE_CHARS,
        wait_timeout: DEFAULT_WAIT_TIMEOUT,
        close_timeout: DEFAULT_CLOSE_TIMEOUT,
        cancellation_token: Support::CancellationToken.new,
        deadline: nil,
        observer: nil
      )
        validate_limit(:max_concurrent, max_concurrent)
        validate_limit(:max_identities, max_identities)
        validate_limit(:max_turns, max_turns)
        validate_limit(:max_queued_turns_per_identity, max_queued_turns_per_identity)
        validate_limit(:max_message_chars, max_message_chars)
        validate_limit(:max_response_chars, max_response_chars)
        validate_timeout(:wait_timeout, wait_timeout)
        validate_timeout(:close_timeout, close_timeout)

        @definitions = definitions.each_with_object({}) do |definition, index|
          raise ArgumentError, "Duplicate subagent kind: #{definition.kind}" if index.key?(definition.kind)

          index[definition.kind] = definition
        end.freeze
        @max_identities = max_identities
        @max_turns = max_turns
        @max_queued_turns_per_identity = max_queued_turns_per_identity
        @max_message_chars = max_message_chars
        @max_response_chars = max_response_chars
        @wait_timeout = wait_timeout
        @close_timeout = close_timeout
        @cancellation_token = cancellation_token.child
        @deadline = deadline
        @observer = observer
        @capacity = Capacity.new(max_concurrent)
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @identities = {}
        @identity_slots = 0
        @turn_count = 0
        @kind_counts = Hash.new(0)
        @cleanup_error = nil
        @closed = false
      end

      def spawn(kind:, task:, mode:, parent_operation_id: nil)
        validate_mode(mode)
        definition, subagent_id = reserve_identity(kind, task)
        return subagent_id unless definition

        begin
          agent = definition.factory.call(subagent_id)
          raise TypeError, "factory result must respond to call" unless agent.respond_to?(:call)
        rescue LittleGhost::CleanupError
          release_identity_reservation
          raise
        rescue => error
          release_identity_reservation
          warn_failure("factory", subagent_id, error)
          emit_factory_failure(definition, subagent_id, error, parent_operation_id:)
          return {
            status: "failed",
            subagent_id: subagent_id,
            kind: definition.kind,
            error: "Subagent could not be created."
          }
        end

        identity = Identity.new(
          subagent_id: subagent_id,
          definition: definition,
          agent: agent,
          history: [].freeze,
          state: {},
          queue: [],
          status: "idle",
          next_turn: 1,
          latest_response_truncated: false,
          progress_sequence: 0
        )

        closed = @mutex.synchronize do
          if @closed
            @identity_slots -= 1
            @turn_count -= 1
            next true
          end
          @identities[subagent_id] = identity
          false
        end
        if closed
          agent.close if agent.respond_to?(:close)
          raise Error, "Subagent manager is closed"
        end

        turn, queued_snapshot = enqueue(
          identity,
          task,
          event: "spawned",
          count_turn: false,
          parent_operation_id:
        )
        return {status: "working", subagent: queued_snapshot} if mode == "async"

        turn.completion.value(cancellation_token: @cancellation_token, deadline: @deadline)
      end

      def send_message(subagent_id:, message:, mode:, parent_operation_id: nil)
        validate_mode(mode)
        identity = @mutex.synchronize do
          ensure_open!
          fetch_identity!(subagent_id)
        end
        queued = enqueue(
          identity,
          message,
          event: "message_queued",
          enforce_limits: true,
          parent_operation_id:
        )
        return queued if queued.is_a?(Hash)

        turn, queued_snapshot = queued
        return {status: "working", subagent: queued_snapshot} if mode == "async"

        turn.completion.value(cancellation_token: @cancellation_token, deadline: @deadline)
      end

      def interrupt(subagent_id:, message:, cancellation_token: @cancellation_token, deadline: @deadline)
        unless message.is_a?(String)
          raise ToolError, "Subagent messages must be strings."
        end
        if message.length > @max_message_chars
          raise ToolError, "Subagent messages cannot exceed #{@max_message_chars} characters."
        end

        identity, turn = @mutex.synchronize do
          ensure_open!
          value = fetch_identity!(subagent_id)
          unless value.agent.respond_to?(:interrupt)
            raise ToolError, "Subagent #{subagent_id.inspect} does not support interruptions."
          end
          unless value.status == "running"
            raise ToolError, "Subagent #{subagent_id.inspect} is not currently running."
          end

          [value, value.current]
        end

        response = identity.agent.interrupt(
          message,
          cancellation_token:,
          deadline:,
          target_operation_id: turn.operation_id
        )
        truncated = response.length > @max_response_chars
        value = {
          status: "interrupted",
          subagent_id: identity.subagent_id,
          kind: identity.definition.kind,
          turn: turn.number,
          response: truncated ? response[0, @max_response_chars] : response
        }
        value[:response_truncated] = true if truncated
        value
      rescue AgentInterruptError => error
        raise ToolError, error.message
      end

      def wait(subagent_ids: nil)
        identities = @mutex.synchronize do
          ensure_open!
          selected_identities(subagent_ids)
        end
        return {status: "finished", subagents: []} if identities.empty?

        deadline = monotonic_time + @wait_timeout
        @mutex.synchronize do
          until identities.all? { |identity| finished?(identity) }
            @cancellation_token.raise_if_cancelled!
            if @deadline && Time.now >= @deadline
              raise DeadlineExceededError, "The run deadline was reached"
            end

            remaining = deadline - monotonic_time
            remaining = [remaining, @deadline - Time.now].min if @deadline
            break unless remaining.positive?

            @condition.wait(@mutex, [remaining, CANCELLATION_POLL_INTERVAL].min)
          end
          status = (identities.all? { |identity| finished?(identity) }) ? "finished" : "still_working"
          {
            status: status,
            subagents: identities.map { |identity| snapshot(identity, include_response: true, include_progress: true) }
          }
        end
      end

      def list
        @mutex.synchronize do
          {status: "ok", subagents: @identities.values.map { |identity| snapshot(identity, include_progress: true) }}
        end
      end

      def tools
        manager = self
        kind_descriptions = definitions.values.map do |definition|
          "- #{definition.kind}: #{definition.description}"
        end.join("\n")
        tools = [
          Tool.define(
            name: "spawn_subagent",
            description: <<~DESCRIPTION.strip,
              Create a new subagent identity for an independent task. Choose sync when the next step depends on this
              response; several sync spawns requested together can still run in parallel. Choose async to continue
              other work immediately, then use wait_for_subagents to check in. Spawning the same kind repeatedly
              creates separate identities.
            DESCRIPTION
            input_schema: {
              type: "object",
              properties: {
                kind: {
                  type: "string",
                  enum: definitions.keys,
                  description: "Kind of subagent to create.\n#{kind_descriptions}"
                },
                task: {type: "string", description: "Independent task to delegate."},
                mode: {
                  type: "string", enum: %w[sync async],
                  description: "Use sync when the next step needs the result; async to continue immediately."
                }
              },
              required: %w[kind task mode],
              additionalProperties: false
            }
          ) do |input, context: nil|
            manager.spawn(
              kind: input.fetch("kind"),
              task: input.fetch("task"),
              mode: input.fetch("mode"),
              parent_operation_id: context&.agent_operation_id
            )
          end,
          Tool.define(
            name: "send_message_to_subagent",
            description: <<~DESCRIPTION.strip,
              Send a follow-up turn to an existing subagent identity. Messages are processed in order after the
              current turn and never interrupt active work. Do not use this for status, steering, stopping, or
              finalization; use interrupt_subagent for an active subagent. Choose sync when the next step depends on
              the later turn, or async to enqueue it and continue immediately.
            DESCRIPTION
            input_schema: {
              type: "object",
              properties: {
                subagent_id: {type: "string", description: "Existing subagent identity."},
                message: {type: "string", description: "Follow-up task or context."},
                mode: {
                  type: "string", enum: %w[sync async],
                  description: "Use sync to wait for this turn; async to enqueue it."
                }
              },
              required: %w[subagent_id message mode],
              additionalProperties: false
            }
          ) do |input, context: nil|
            manager.send_message(
              subagent_id: input.fetch("subagent_id"),
              message: input.fetch("message"),
              mode: input.fetch("mode"),
              parent_operation_id: context&.agent_operation_id
            )
          end,
          Tool.define(
            name: "interrupt_subagent",
            description: <<~DESCRIPTION.strip,
              Interrupt an actively running subagent in its current turn. The message is added at the next model
              boundary. This call waits for that model response and returns only its ordinary text; tool calls from
              the same response remain with the subagent and continue its current run.
            DESCRIPTION
            input_schema: {
              type: "object",
              properties: {
                subagent_id: {type: "string", description: "Actively running subagent identity."},
                message: {type: "string", description: "Status question, steering context, or request to finish."}
              },
              required: %w[subagent_id message],
              additionalProperties: false
            }
          ) do |input, context: nil|
            options = {}
            options[:cancellation_token] = context.cancellation_token if context
            options[:deadline] = context.deadline if context&.deadline
            manager.interrupt(
              subagent_id: input.fetch("subagent_id"),
              message: input.fetch("message"),
              **options
            )
          end,
          Tool.define(
            name: "wait_for_subagents",
            description: <<~DESCRIPTION.strip,
              Wait briefly for selected subagents, or all subagents when omitted. A still_working response is expected
              when work takes longer than this check-in window. Call this tool again to keep waiting; timeout is not an
              error and does not cancel the subagents.
            DESCRIPTION
            input_schema: {
              type: "object",
              properties: {
                subagent_ids: {
                  type: "array", items: {type: "string"},
                  description: "Subagent identities to wait for; omit to wait for all."
                }
              },
              additionalProperties: false
            }
          ) { |input| manager.wait(subagent_ids: input["subagent_ids"]) },
          Tool.define(
            name: "list_subagents",
            description: "List subagent identities, statuses, turns, and queued work without waiting.",
            input_schema: {type: "object", additionalProperties: false}
          ) { |_input| manager.list }
        ]
        tools.first.define_method(:close) { manager.close }
        tools
      end

      def close
        workers = @mutex.synchronize do
          return if @closed

          @closed = true
          @cancellation_token.cancel
          @identities.each_value do |identity|
            next if %w[idle failed cancelled].include?(identity.status)

            turn = identity.current
            identity.status = "cancelled"
            turn&.completion&.resolve(cancelled_turn(identity, turn))
            identity.progress_message = nil
            identity.current_turn = nil
            identity.current = nil
            cancel_queued_turns(identity)
            emit("cancelled", identity, turn:)
          end
          @condition.broadcast
          @identities.values.filter_map(&:worker)
        end

        deadline = monotonic_time + @close_timeout
        cooperative_deadline = monotonic_time + (@close_timeout / 2.0)
        workers.each do |worker|
          remaining = cooperative_deadline - monotonic_time
          break unless remaining.positive?

          worker.join(remaining)
        end
        workers.select(&:alive?).each(&:kill)
        workers.each do |worker|
          remaining = deadline - monotonic_time
          break unless remaining.positive?

          worker.join(remaining)
        end
        first_error = @mutex.synchronize { @cleanup_error }
        survivors = workers.select(&:alive?)
        unless survivors.empty?
          first_error ||= CleanupError.new(
            "#{survivors.length} subagent worker(s) did not stop within #{@close_timeout} seconds"
          )
        end
        agents = @mutex.synchronize { @identities.values.map(&:agent).reverse.uniq(&:object_id) }
        agents.each do |agent|
          agent.close if agent.respond_to?(:close)
        rescue => error
          first_error ||= error
        end
        raise first_error if first_error
      end

      private

      def reserve_identity(kind, task)
        @mutex.synchronize do
          ensure_open!
          definition = @definitions[kind]
          raise ToolError, "Unknown subagent kind: #{kind}" unless definition

          return [nil, identity_capacity_response] if @identity_slots >= @max_identities

          rejection = reject_turn_locked(task)
          return [nil, rejection] if rejection

          @identity_slots += 1
          @turn_count += 1
          @kind_counts[kind] += 1
          [definition, "#{kind}-#{@kind_counts[kind]}"]
        end
      end

      def release_identity_reservation
        @mutex.synchronize do
          @identity_slots -= 1
          @turn_count -= 1
        end
      end

      def enqueue(
        identity,
        message,
        event:,
        enforce_limits: false,
        count_turn: true,
        parent_operation_id: nil
      )
        turn = nil
        queued_snapshot = nil
        @mutex.synchronize do
          ensure_open!
          if enforce_limits
            if %w[failed cancelled].include?(identity.status)
              raise ToolError,
                "Subagent #{identity.subagent_id.inspect} is #{identity.status}; spawn a new identity."
            end
            rejection = reject_turn_locked(message, identity: identity)
            return rejection if rejection
          end

          turn = Turn.new(
            number: identity.next_turn,
            message: message,
            completion: Completion.new,
            operation_id: SecureRandom.uuid,
            parent_operation_id:
          )
          identity.next_turn += 1
          @turn_count += 1 if count_turn
          identity.queue << turn
          identity.status = "queued" unless identity.status == "running"
          emit(event, identity, turn:)
          queued_snapshot = snapshot(identity)
          unless identity.worker&.alive?
            identity.worker = Thread.new { run_identity(identity) }
          end
          @condition.broadcast
        end
        [turn, queued_snapshot]
      end

      def run_identity(identity)
        loop do
          turn = @mutex.synchronize do
            if @closed
              cancel_queued_turns(identity)
              identity.worker = nil
              @condition.broadcast
              return
            end

            value = identity.queue.shift
            unless value
              identity.status = "idle"
              identity.worker = nil
              @condition.broadcast
              return
            end
            identity.current_turn = value.number
            identity.current = value
            identity.status = "queued"
            value
          end

          failed = false
          cancelled = false
          ran = begin
            @capacity.synchronize(@cancellation_token, deadline: @deadline) do
              should_run = @mutex.synchronize do
                unless @closed
                  identity.status = "running"
                  identity.progress_message = nil
                  emit("turn_started", identity, turn:)
                  @condition.broadcast
                  true
                end
              end
              next unless should_run

              begin
                options = {cancellation_token: @cancellation_token}
                if identity.agent.is_a?(Agent)
                  options[:deadline] = @deadline
                  options[:parent_operation_id] = turn.operation_id
                  options[:history] = identity.history
                  options[:context] = identity.state
                end
                result = if identity.agent.is_a?(Agent)
                  run_agent_turn(identity, turn, options)
                else
                  identity.agent.call(turn.message, **options)
                end
                finish_turn(identity, turn, result)
              rescue CancelledError
                cancelled = true
                cancel_unrun_turn(identity, turn)
              rescue LittleGhost::CleanupError => error
                failed = true
                record_cleanup_error(error)
                fail_turn(identity, turn, error, propagate: true)
              rescue => error
                failed = true
                fail_turn(identity, turn, error)
              end
            end
          rescue CancelledError
            cancelled = true
            cancel_unrun_turn(identity, turn)
            false
          rescue DeadlineExceededError => error
            failed = true
            fail_turn(identity, turn, error)
            false
          end
          cancel_unrun_turn(identity, turn) unless ran || failed || cancelled
          return if failed || cancelled
        end
      ensure
        @mutex.synchronize do
          identity.worker = nil if identity.worker == Thread.current
          @condition.broadcast
        end
      end

      def run_agent_turn(identity, turn, options)
        result = nil
        identity.agent.stream(turn.message, **options).each do |event|
          capture_progress(identity, turn, event)
          result = event.data[:result] if event.type == :invocation_stop
        end
        result
      end

      def capture_progress(identity, turn, event)
        return unless event.type == :message_stop

        response = event.data[:response]
        return unless response&.stop_reason == :tool_use
        return unless response.message.role == :assistant
        return if response.message.content.grep(Content::ToolUse).empty?

        message = normalize_progress(response.message)
        return if message.empty?

        @mutex.synchronize do
          return unless identity.current.equal?(turn)
          return if identity.progress_message == message

          identity.progress_message = message
          identity.progress_sequence += 1
          @condition.broadcast
        end
      end

      def normalize_progress(message)
        normalized = +""
        pending_space = false
        source_chars = 0
        message.content.each do |block|
          next unless block.is_a?(Content::Text)

          block.text.each_char do |character|
            return normalized if source_chars >= MAX_PROGRESS_SOURCE_CHARS

            source_chars += 1
            if character.match?(PROGRESS_SEPARATOR)
              pending_space = !normalized.empty?
              next
            end

            normalized << " " if pending_space
            return normalized if normalized.length >= MAX_PROGRESS_CHARS

            pending_space = false
            normalized << character
            return normalized if normalized.length >= MAX_PROGRESS_CHARS
          end
        end
        normalized
      end

      def finish_turn(identity, turn, result)
        structured = result.is_a?(RunResult) && result.structured?
        response = if structured
          result.structured_result.value
        elsif result.respond_to?(:text)
          result.text.to_s
        else
          result.to_s
        end
        serialized_response = response.is_a?(String) ? response : JSON.generate(response)
        if structured && serialized_response.length > @max_response_chars
          raise StructuredResultError.new(
            "The structured subagent result exceeds the response limit",
            schema_name: result.structured_result.schema_name,
            validation_errors: ["result exceeds #{@max_response_chars} characters"]
          )
        end
        truncated = serialized_response.length > @max_response_chars
        response = serialized_response[0, @max_response_chars] if truncated

        @mutex.synchronize do
          if @closed
            turn.completion.resolve(cancelled_turn(identity, turn))
            return
          end

          retain_agent_conversation(identity, result)
          identity.latest_turn = turn.number
          identity.latest_response = response
          identity.latest_response_truncated = truncated
          identity.latest_error = nil
          identity.progress_message = nil
          identity.current_turn = nil
          identity.current = nil
          value = {
            status: "finished",
            subagent_id: identity.subagent_id,
            kind: identity.definition.kind,
            turn: turn.number,
            response: response
          }
          value[:response_truncated] = true if truncated
          turn.completion.resolve(value)
          emit("turn_finished", identity, turn:)
          @condition.broadcast
        end
      end

      def retain_agent_conversation(identity, result)
        return unless identity.agent.is_a?(Agent) && result.is_a?(RunResult)

        identity.history = result.messages.reject { |message| message.role == :system }.freeze
        identity.state = result.state
      end

      def fail_turn(identity, turn, error, propagate: false)
        @mutex.synchronize do
          return if @closed

          warn_failure("turn", identity.subagent_id, error)
          identity.latest_turn = turn.number
          identity.latest_response = nil
          identity.latest_response_truncated = false
          identity.latest_error = "Subagent turn failed."
          identity.progress_message = nil
          identity.current_turn = nil
          identity.current = nil
          identity.status = "failed"
          if propagate
            turn.completion.reject(error)
          else
            turn.completion.resolve(
              status: "failed",
              subagent_id: identity.subagent_id,
              kind: identity.definition.kind,
              turn: turn.number,
              error: identity.latest_error
            )
          end
          emit("turn_failed", identity, turn:)
          fail_queued_turns(identity)
          @condition.broadcast
        end
      end

      def cancel_unrun_turn(identity, turn)
        @mutex.synchronize do
          newly_cancelled = identity.status != "cancelled"
          turn.completion.resolve(cancelled_turn(identity, turn))
          identity.progress_message = nil
          identity.current_turn = nil
          identity.current = nil
          identity.status = "cancelled"
          cancel_queued_turns(identity)
          emit("cancelled", identity, turn:) if newly_cancelled
          @condition.broadcast
        end
      end

      def record_cleanup_error(error)
        @mutex.synchronize { @cleanup_error ||= error }
      end

      def cancelled_turn(identity, turn)
        {
          status: "cancelled",
          subagent_id: identity.subagent_id,
          kind: identity.definition.kind,
          turn: turn.number,
          error: "Subagent turn was cancelled."
        }
      end

      def cancel_queued_turns(identity)
        identity.queue.each do |turn|
          turn.completion.resolve(cancelled_turn(identity, turn))
          emit("cancelled", identity, turn:)
        end
        identity.queue.clear
      end

      def fail_queued_turns(identity)
        identity.queue.each do |turn|
          turn.completion.resolve(
            status: "failed",
            subagent_id: identity.subagent_id,
            kind: identity.definition.kind,
            turn: turn.number,
            error: "A previous turn failed; spawn a new identity."
          )
          emit("turn_failed", identity, turn:)
        end
        identity.queue.clear
      end

      def reject_turn_locked(message, identity: nil)
        unless message.is_a?(String)
          return {status: "invalid_request", message: "Subagent messages must be strings."}
        end
        if message.length > @max_message_chars
          return {
            status: "invalid_request",
            message: "Subagent messages cannot exceed #{@max_message_chars} characters."
          }
        end
        if @turn_count >= @max_turns
          return {
            status: "capacity_reached",
            limit: @max_turns,
            message: "This run has reached its subagent turn limit."
          }
        end
        if identity && identity.queue.length >= @max_queued_turns_per_identity
          return {
            status: "capacity_reached",
            limit: @max_queued_turns_per_identity,
            message: "Subagent #{identity.subagent_id.inspect} has reached its queued turn limit.",
            subagent: snapshot(identity)
          }
        end
        nil
      end

      def identity_capacity_response
        {
          status: "capacity_reached",
          limit: @max_identities,
          message: "This run has reached its subagent identity limit."
        }
      end

      def selected_identities(subagent_ids)
        return @identities.values if subagent_ids.nil?
        raise ToolError, "subagent_ids must be unique" if subagent_ids.uniq.length != subagent_ids.length

        subagent_ids.map { |subagent_id| fetch_identity!(subagent_id) }
      end

      def fetch_identity!(subagent_id)
        @identities.fetch(subagent_id) { raise ToolError, "Unknown subagent id: #{subagent_id}" }
      end

      def snapshot(identity, include_response: false, include_progress: false)
        value = {
          subagent_id: identity.subagent_id,
          kind: identity.definition.kind,
          status: identity.status,
          current_turn: identity.current_turn,
          latest_turn: identity.latest_turn,
          queued_turns: identity.queue.length
        }
        if include_response && identity.latest_response
          value[:response] = identity.latest_response
          value[:response_truncated] = true if identity.latest_response_truncated
        end
        if include_progress && identity.progress_message && %w[queued running].include?(identity.status)
          value[:progress] = {
            message: identity.progress_message,
            sequence: identity.progress_sequence
          }
        end
        value[:error] = identity.latest_error if identity.latest_error
        value
      end

      def finished?(identity)
        %w[idle failed cancelled].include?(identity.status)
      end

      def emit(event, identity, turn: nil)
        return unless @observer

        value = {
          event: event,
          subagent_id: identity.subagent_id,
          kind: identity.definition.kind,
          status: identity.status
        }
        if turn
          value[:turn] = turn.respond_to?(:number) ? turn.number : turn
          value[:operation_id] = turn.operation_id if turn.respond_to?(:operation_id) && turn.operation_id
          if turn.respond_to?(:parent_operation_id) && turn.parent_operation_id
            value[:parent_operation_id] = turn.parent_operation_id
          end
        end
        @observer.call(value.freeze)
      rescue
        nil
      end

      def emit_factory_failure(definition, subagent_id, error, parent_operation_id: nil)
        return unless @observer

        @observer.call({
          event: "factory_failed",
          subagent_id:,
          kind: definition.kind,
          status: "failed",
          error_type: error.class.name,
          parent_operation_id:
        }.compact.freeze)
      rescue
        nil
      end

      def ensure_open!
        raise Error, "Subagent manager is closed" if @closed
      end

      def validate_mode(mode)
        raise ToolError, "mode must be 'sync' or 'async'" unless %w[sync async].include?(mode)
      end

      def validate_limit(name, value)
        raise ArgumentError, "#{name} must be at least 1" unless value.is_a?(Integer) && value >= 1
      end

      def validate_timeout(name, value)
        raise ArgumentError, "#{name} cannot be negative" unless value.is_a?(Numeric) && value >= 0
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def warn_failure(stage, subagent_id, error)
        warn("little_ghost_subagent_#{stage}_failed subagent_id=#{subagent_id} error=#{error.class}")
      rescue
        nil
      end
    end
  end
end
