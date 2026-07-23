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
      DEFAULT_WAIT_TIMEOUT = 30.0
      DEFAULT_CLOSE_TIMEOUT = 5.0
      CANCELLATION_POLL_INTERVAL = 0.05

      Turn = Struct.new(:number, :message, :completion, :operation_id)
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
        :latest_error
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
        @cancellation_token = cancellation_token
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

      def spawn(kind:, task:, mode:)
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
          latest_response_truncated: false
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

        turn, queued_snapshot = enqueue(identity, task, event: "spawned", count_turn: false)
        return {status: "working", subagent: queued_snapshot} if mode == "async"

        turn.completion.value(cancellation_token: @cancellation_token, deadline: @deadline)
      end

      def send_message(subagent_id:, message:, mode:)
        validate_mode(mode)
        identity = @mutex.synchronize do
          ensure_open!
          fetch_identity!(subagent_id)
        end
        queued = enqueue(identity, message, event: "message_queued", enforce_limits: true)
        return queued if queued.is_a?(Hash)

        turn, queued_snapshot = queued
        return {status: "working", subagent: queued_snapshot} if mode == "async"

        turn.completion.value(cancellation_token: @cancellation_token, deadline: @deadline)
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
          {status: status, subagents: identities.map { |identity| snapshot(identity, include_response: true) }}
        end
      end

      def list
        @mutex.synchronize do
          {status: "ok", subagents: @identities.values.map { |identity| snapshot(identity) }}
        end
      end

      def tools
        manager = self
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
                kind: {type: "string", enum: definitions.keys, description: "Kind of subagent to create."},
                task: {type: "string", description: "Independent task to delegate."},
                mode: {
                  type: "string", enum: %w[sync async],
                  description: "Use sync when the next step needs the result; async to continue immediately."
                }
              },
              required: %w[kind task mode],
              additionalProperties: false
            }
          ) { |input| manager.spawn(kind: input.fetch("kind"), task: input.fetch("task"), mode: input.fetch("mode")) },
          Tool.define(
            name: "send_message_to_subagent",
            description: <<~DESCRIPTION.strip,
              Send a follow-up turn to an existing subagent identity. Messages are processed in order. Choose sync
              when the next step depends on this turn, or async to enqueue it and continue immediately.
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
          ) do |input|
            manager.send_message(
              subagent_id: input.fetch("subagent_id"),
              message: input.fetch("message"),
              mode: input.fetch("mode")
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

      def enqueue(identity, message, event:, enforce_limits: false, count_turn: true)
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

          turn = Turn.new(number: identity.next_turn, message: message, completion: Completion.new)
          identity.next_turn += 1
          @turn_count += 1 if count_turn
          identity.queue << turn
          identity.status = "queued" unless identity.status == "running"
          emit(event, identity, turn: turn.number)
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
                  turn.operation_id = SecureRandom.uuid
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
                result = identity.agent.call(turn.message, **options)
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

      def finish_turn(identity, turn, result)
        @mutex.synchronize do
          if @closed
            turn.completion.resolve(cancelled_turn(identity, turn))
            return
          end

          retain_agent_conversation(identity, result)
          response = result.respond_to?(:text) ? result.text.to_s : result.to_s
          truncated = response.length > @max_response_chars
          response = response[0, @max_response_chars]
          identity.latest_turn = turn.number
          identity.latest_response = response
          identity.latest_response_truncated = truncated
          identity.latest_error = nil
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
        identity.queue.each { |turn| turn.completion.resolve(cancelled_turn(identity, turn)) }
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

      def snapshot(identity, include_response: false)
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
        end
        @observer.call(value.freeze)
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
