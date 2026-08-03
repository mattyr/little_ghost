# frozen_string_literal: true

require "securerandom"
require "base64"
require "digest"
require "time"
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
      DEFAULT_LIST_LIMIT = 20
      MAX_LIST_LIMIT = 100
      MAX_PROGRESS_CHARS = 160
      MAX_PROGRESS_SOURCE_CHARS = 4_096
      PROGRESS_SEPARATOR = /[\p{Z}\p{Cc}\p{Cf}]/
      CANCELLATION_POLL_INTERVAL = 0.05
      REGISTRY_VERSION = 2
      CURSOR_MAX_BYTES = 512
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      InterruptExchange = Struct.new(:message, :response, :complete)
      Turn = Struct.new(
        :number,
        :message,
        :completion,
        :operation_id,
        :parent_operation_id,
        :interrupts,
        :interruption_metadata,
        :interruption_ids
      )
      Identity = Struct.new(
        :subagent_id,
        :conversation_id,
        :definition,
        :agent,
        :session,
        :durable,
        :resumed,
        :updated_at,
        :committed_count,
        :commit_id,
        :commit_slot,
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
        :latest_response_turn,
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

      class << self
        def parent_link(session)
          Digest::SHA256.hexdigest("#{session.actor_id}\0#{session.id}")
        end

        def registry_session_id(session)
          "lg_subagent_registry_#{parent_link(session)}"
        end

        def conversation_session_id(conversation_id)
          "lg_subagent_conversation_#{conversation_id}"
        end

        def commit_session_id(conversation_id, slot)
          "lg_subagent_commit_#{conversation_id}_#{slot}"
        end
      end

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
        observer: nil,
        parent_session: nil,
        parent_agent_path: AgentPath::ROOT
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
        @parent_session = parent_session
        @parent_agent_path = AgentPath.validate!(parent_agent_path)
        @parent_link = parent_session && self.class.parent_link(parent_session)
        @registry_session = parent_session && registry_session
        @capacity = Capacity.new(max_concurrent)
        @mutex = Mutex.new
        @registry_mutex = Mutex.new
        @restore_mutex = Mutex.new
        @condition = ConditionVariable.new
        @identities = {}
        @reserved_agent_paths = {}
        @identity_slots = 0
        @turn_count = 0
        @closed = false
        restore_identities
      end

      def spawn(kind:, task_name:, task:, mode:, parent_operation_id: nil, context: nil)
        validate_mode(mode)
        definition, subagent_id = reserve_identity(kind, task, task_name:)
        return subagent_id unless definition

        conversation_id = SecureRandom.uuid
        begin
          agent = build_agent(definition, subagent_id, conversation_id)
          raise TypeError, "factory result must respond to call" unless agent.respond_to?(:call)
        rescue LittleGhost::CleanupError
          release_identity_reservation(subagent_id)
          raise
        rescue => error
          release_identity_reservation(subagent_id)
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
          conversation_id: conversation_id,
          definition: definition,
          agent: agent,
          session: definition.persist && @parent_session && child_session(conversation_id),
          durable: definition.persist && !!@parent_session,
          resumed: false,
          updated_at: Time.now.utc.iso8601(6),
          committed_count: 0,
          commit_slot: 1,
          history: [].freeze,
          state: {},
          queue: [],
          status: "idle",
          next_turn: 1,
          latest_response_truncated: false,
          progress_sequence: 0
        )
        observe_delegated_activity(identity)

        closed = @mutex.synchronize do
          if @closed
            @reserved_agent_paths.delete(subagent_id)
            @identity_slots -= 1
            @turn_count -= 1
            next true
          end
          @reserved_agent_paths.delete(subagent_id)
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
          parent_operation_id:,
          context:
        )
        return {status: "working", subagent: queued_snapshot} if mode == "async"

        turn.completion.value(cancellation_token: @cancellation_token, deadline: @deadline)
      end

      def send_message(subagent_id:, message:, mode:, parent_operation_id: nil, context: nil)
        validate_mode(mode)
        identity = @mutex.synchronize do
          ensure_open!
          fetch_identity!(subagent_id)
        end
        restore_agent!(identity)
        queued = enqueue(
          identity,
          message,
          event: "message_queued",
          enforce_limits: true,
          parent_operation_id:,
          context:
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

        exchange = InterruptExchange.new(message:, complete: false)
        identity, turn = @mutex.synchronize do
          ensure_open!
          value = fetch_identity!(subagent_id)
          unless value.agent.respond_to?(:interrupt_response)
            raise ToolError, "Subagent #{subagent_id.inspect} does not support interruptions."
          end
          unless value.status == "running"
            raise ToolError, "Subagent #{subagent_id.inspect} is not currently running."
          end
          if value.current.interrupts.length >= @max_queued_turns_per_identity
            raise ToolError, "Subagent #{subagent_id.inspect} has reached its interrupt limit."
          end
          interrupt_chars = value.current.interrupts.sum { |pending| pending.message.length }
          if interrupt_chars + message.length > @max_message_chars
            raise ToolError, "Subagent interrupt messages cannot exceed #{@max_message_chars} total characters."
          end

          value.current.interrupts << exchange
          [value, value.current]
        end

        interrupt_response = begin
          identity.agent.interrupt_response(
            message,
            cancellation_token:,
            deadline:,
            target_operation_id: turn.operation_id
          )
        rescue
          @mutex.synchronize do
            turn.interrupts.delete(exchange)
            @condition.broadcast
          end
          raise
        end
        response = interrupt_response.text
        truncated = response.length > @max_response_chars
        returned_response = truncated ? response[0, @max_response_chars] : response
        @mutex.synchronize do
          used_response_chars = turn.interrupts.sum do |pending|
            pending.equal?(exchange) ? 0 : pending.response.to_s.length
          end
          remaining_response_chars = [@max_response_chars - used_response_chars, 0].max
          exchange.response = returned_response[0, remaining_response_chars]
          exchange.complete = true
          @condition.broadcast
        end
        subagent = @mutex.synchronize do
          snapshot(identity, include_response: true, include_progress: true)
        end
        value = {
          status: "interruption_delivered",
          subagent_id: identity.subagent_id,
          kind: identity.definition.kind,
          subagent:,
          turn: turn.number,
          response: returned_response,
          response_disposition: interrupt_response.tool_calls? ? "text_with_tool_calls" : "text_only"
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

      def list(kind: nil, limit: DEFAULT_LIST_LIMIT, cursor: nil)
        cursor = nil if cursor == ""
        unless limit.is_a?(Integer) && limit.between?(1, MAX_LIST_LIMIT)
          raise ToolError, "limit must be between 1 and #{MAX_LIST_LIMIT}"
        end
        if kind && !definitions.key?(kind)
          raise ToolError, "Unknown subagent kind: #{kind}"
        end

        @mutex.synchronize do
          identities = @identities.values
          identities = identities.select { |identity| identity.definition.kind == kind } if kind
          identities = identities.sort_by { |identity| [identity.updated_at.to_s, identity.subagent_id] }.reverse
          if cursor
            boundary = decode_cursor(cursor)
            identities = identities.drop_while do |identity|
              ([identity.updated_at.to_s, identity.subagent_id] <=> boundary) >= 0
            end
          end
          page = identities.first(limit)
          value = {
            status: "ok",
            subagents: page.map { |identity| snapshot(identity, include_progress: true) }
          }
          value[:next_cursor] = encode_cursor(page.last) if identities.length > page.length
          value
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
              Create a new subagent identity for an independent task. Mode controls delivery: sync waits for the
              response in this call, while async returns immediately and leaves the response for
              wait_for_subagents. Several sync spawns requested together can still run in parallel. Give the task a
              concise lowercase name. The returned identity is its canonical path beneath the current agent. Task
              names must be unique among that agent's children.
            DESCRIPTION
            input_schema: {
              type: "object",
              properties: {
                kind: {
                  type: "string",
                  enum: definitions.keys,
                  description: "Kind of subagent to create.\n#{kind_descriptions}"
                },
                task_name: {
                  type: "string",
                  pattern: "^[a-z0-9_]+$",
                  maxLength: AgentPath::MAX_NAME_LENGTH,
                  description: "Friendly task name using lowercase letters, digits, and underscores."
                },
                task: {type: "string", description: "Independent task to delegate."},
                mode: {
                  type: "string", enum: %w[sync async],
                  description: "sync waits for the response; async returns while the subagent continues."
                }
              },
              required: %w[kind task_name task mode],
              additionalProperties: false
            }
          ) do |input, context: nil|
            manager.spawn(
              kind: input.fetch("kind"),
              task_name: input.fetch("task_name"),
              task: input.fetch("task"),
              mode: input.fetch("mode"),
              context:,
              parent_operation_id: context&.agent_operation_id
            )
          end,
          Tool.define(
            name: "send_message_to_subagent",
            description: <<~DESCRIPTION.strip,
              Send a follow-up turn to an existing active or persisted subagent identity. Persisted conversations
              are restored transparently before the follow-up. Messages are processed in order after the
              current turn and never interrupt active work. Do not use this for status, steering, stopping, or
              finalization; use interrupt_subagent for an active subagent. Mode controls delivery: sync waits for the
              later turn's response, while async enqueues the turn and returns immediately.
            DESCRIPTION
            input_schema: {
              type: "object",
              properties: {
                subagent_id: {type: "string", description: "Existing subagent identity."},
                message: {type: "string", description: "Follow-up task or context."},
                mode: {
                  type: "string", enum: %w[sync async],
                  description: "sync waits for this turn; async enqueues it and returns immediately."
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
              context:,
              parent_operation_id: context&.agent_operation_id
            )
          end,
          Tool.define(
            name: "interrupt_subagent",
            description: <<~DESCRIPTION.strip,
              Interrupt an actively running subagent in its current turn. The message is added at the next model
              boundary. This call waits for that model response and reports its ordinary text, whether the same
              response also initiated tool work, and the subagent's current lifecycle state. Delivery is distinct
              from stopping: tool work from that response remains with the subagent and its current run may continue.
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
              error and does not cancel the subagents. A successful settled turn is returned as response. When newer
              work is queued, running, persisting, failed, or cancelled, the most recent successful result may instead
              appear as previous_response for context; it is not the result of that newer work. Inspect each subagent's
              status and keep waiting while selected work is active.
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
            description: <<~DESCRIPTION.strip,
              List active and persisted subagent conversations newest-first without restoring inactive agents.
              Use kind to filter. Omit cursor for the first page; to continue, pass the exact non-empty next_cursor
              from the preceding result.
            DESCRIPTION
            input_schema: {
              type: "object",
              properties: {
                kind: {type: "string", enum: definitions.keys},
                limit: {type: "integer", minimum: 1, maximum: MAX_LIST_LIMIT},
                cursor: {type: "string"}
              },
              additionalProperties: false
            }
          ) do |input|
            manager.list(
              kind: input["kind"],
              limit: input.fetch("limit", DEFAULT_LIST_LIMIT),
              cursor: input["cursor"]
            )
          end
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
            next if %w[idle failed cancelled persisting].include?(identity.status)

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
        first_error = nil
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

      def restore_identities
        return unless @registry_session

        registry = @registry_session.state
        validate_session_metadata!(@registry_session, registry_metadata)
        version = registry["version"] || registry[:version]
        return unless version == REGISTRY_VERSION

        conversations = registry["conversations"] || registry[:conversations]
        return unless conversations.is_a?(Hash)

        restored = conversations.filter_map do |subagent_id, record|
          normalized = normalize_registry_record(subagent_id, record)
          next unless normalized

          definition = @definitions[normalized.fetch(:kind)]
          next unless definition&.persist

          conversation_id = normalized.fetch(:conversation_id)
          session = child_session(conversation_id)
          Identity.new(
            subagent_id: normalized.fetch(:subagent_id),
            conversation_id:,
            definition:,
            agent: nil,
            session:,
            durable: true,
            resumed: true,
            updated_at: normalized.fetch(:updated_at),
            committed_count: normalized.fetch(:message_count),
            commit_id: normalized.fetch(:commit_id),
            commit_slot: normalized.fetch(:commit_slot),
            history: [].freeze,
            state: {},
            queue: [],
            status: "idle",
            next_turn: normalized.fetch(:latest_turn) + 1,
            latest_turn: normalized.fetch(:latest_turn),
            latest_response_truncated: false,
            progress_sequence: 0
          )
        end
        restored.sort_by { |identity| [identity.updated_at, identity.subagent_id] }.reverse
          .first(@max_identities)
          .each { |identity| @identities[identity.subagent_id] = identity }
      rescue ProtocolError
        raise
      rescue => error
        raise ProtocolError, "Subagent conversation registry is invalid: #{error.class}"
      end

      def registry_session
        Session.new(
          id: self.class.registry_session_id(@parent_session),
          actor_id: @parent_session.actor_id,
          store: @parent_session.store,
          metadata: registry_metadata
        )
      end

      def child_session(conversation_id)
        Session.new(
          id: self.class.conversation_session_id(conversation_id),
          actor_id: @parent_session.actor_id,
          store: @parent_session.store,
          metadata: child_metadata(conversation_id)
        )
      end

      def commit_session(conversation_id, slot, commit_id, message_count)
        Session.new(
          id: self.class.commit_session_id(conversation_id, slot),
          actor_id: @parent_session.actor_id,
          store: @parent_session.store,
          metadata: commit_metadata(conversation_id, commit_id, message_count)
        )
      end

      def load_committed_state(identity)
        commit = commit_session(
          identity.conversation_id,
          identity.commit_slot,
          identity.commit_id,
          identity.committed_count
        )
        snapshot = commit.load
        validate_session_metadata!(
          commit,
          commit_metadata(identity.conversation_id, identity.commit_id, identity.committed_count)
        )
        raise ProtocolError, "Subagent committed state snapshot is missing" unless snapshot

        snapshot.fetch(:state)
      end

      def build_agent(definition, subagent_id, conversation_id)
        agent = if definition.accepts_conversation_id
          definition.factory.call(subagent_id, conversation_id)
        else
          definition.factory.call(subagent_id)
        end
        if agent.is_a?(Agent) && agent.agent_path != subagent_id
          raise ConfigurationError,
            "Subagent factory built #{agent.agent_path.inspect}; it must use canonical agent_path #{subagent_id.inspect}."
        end

        agent
      end

      def restore_agent!(identity)
        return if identity.agent

        agent = nil
        @restore_mutex.synchronize do
          return if identity.agent

          snapshot = identity.session.load
          validate_session_metadata!(identity.session, child_metadata(identity.conversation_id))
          committed_state = load_committed_state(identity)
          messages = snapshot&.fetch(:messages) || []
          snapshot_state = snapshot&.fetch(:state) || {}
          if messages.length < identity.committed_count
            raise ProtocolError, "Subagent conversation is shorter than its committed boundary"
          end
          identity.history = messages.first(identity.committed_count).freeze
          identity.state = mutable_copy(committed_state)
          if messages.length != identity.committed_count ||
              snapshot_state != committed_state
            identity.session.replace(
              messages: identity.history,
              state: identity.state,
              metadata: child_metadata(identity.conversation_id)
            )
          end
          agent = build_agent(identity.definition, identity.subagent_id, identity.conversation_id)
          raise TypeError, "factory result must respond to call" unless agent.respond_to?(:call)

          @mutex.synchronize do
            ensure_open!
            identity.agent = agent
          end
        end
      rescue LittleGhost::CleanupError
        agent.close if agent&.respond_to?(:close)
        raise
      rescue => error
        agent.close if agent&.respond_to?(:close)
        warn_failure("factory", identity.subagent_id, error)
        emit_factory_failure(identity.definition, identity.subagent_id, error)
        raise ToolError, "Subagent could not be restored."
      end

      def persist_registry(identity, message_count:, state:)
        return unless @registry_session

        @registry_mutex.synchronize do
          commit_id = SecureRandom.uuid
          commit_slot = (identity.commit_slot == 0) ? 1 : 0
          commit = commit_session(identity.conversation_id, commit_slot, commit_id, message_count)
          commit.replace(
            messages: [],
            state:,
            metadata: commit_metadata(identity.conversation_id, commit_id, message_count)
          )
          @registry_session.synchronize do
            current = registry_session
            registry = current.state
            validate_session_metadata!(current, registry_metadata)
            registry = {"version" => REGISTRY_VERSION, "conversations" => {}} unless
              (registry["version"] || registry[:version]) == REGISTRY_VERSION
            conversations = registry["conversations"] ||= {}
            identity.updated_at = Time.now.utc.iso8601(6)
            conversations[identity.subagent_id] = {
              "conversation_id" => identity.conversation_id,
              "kind" => identity.definition.kind,
              "latest_turn" => identity.current.number,
              "updated_at" => identity.updated_at,
              "message_count" => message_count,
              "commit_id" => commit_id,
              "commit_slot" => commit_slot
            }
            retained = conversations.filter_map do |subagent_id, record|
              normalized = normalize_registry_record(subagent_id, record)
              definition = normalized && @definitions[normalized.fetch(:kind)]
              [subagent_id, record] if normalized && definition&.persist
            end.sort_by do |subagent_id, record|
              [(record["updated_at"] || record[:updated_at]).to_s, subagent_id]
            end.reverse.first(@max_identities).to_h
            registry["conversations"] = retained
            current.replace(messages: [], state: registry, metadata: registry_metadata)
            @registry_session = current
            identity.commit_id = commit_id
            identity.commit_slot = commit_slot
          end
        end
      end

      def registry_metadata
        {
          "little_ghost_kind" => "subagent_registry",
          "little_ghost_parent_link" => @parent_link
        }
      end

      def child_metadata(conversation_id)
        {
          "little_ghost_kind" => "subagent_conversation",
          "little_ghost_parent_link" => @parent_link,
          "little_ghost_conversation_id" => conversation_id
        }
      end

      def commit_metadata(conversation_id, commit_id, message_count)
        {
          "little_ghost_kind" => "subagent_commit",
          "little_ghost_parent_link" => @parent_link,
          "little_ghost_conversation_id" => conversation_id,
          "little_ghost_commit_id" => commit_id,
          "little_ghost_message_count" => message_count
        }
      end

      def validate_session_metadata!(session, expected)
        actual = session.metadata
        return if expected.all? { |key, value| actual[key] == value || actual[key.to_sym] == value }

        raise ProtocolError, "Subagent session metadata does not match its parent conversation"
      end

      def normalize_registry_record(subagent_id, record)
        return unless subagent_id.is_a?(String)
        return unless AgentPath.immediate_child?(subagent_id, @parent_agent_path)
        return unless record.is_a?(Hash)

        conversation_id = record["conversation_id"] || record[:conversation_id]
        kind = record["kind"] || record[:kind]
        latest_turn = record["latest_turn"] || record[:latest_turn]
        updated_at = record["updated_at"] || record[:updated_at]
        message_count = record["message_count"] || record[:message_count]
        commit_id = record["commit_id"] || record[:commit_id]
        commit_slot = record["commit_slot"] || record[:commit_slot]
        return unless conversation_id.is_a?(String) && conversation_id.match?(UUID_PATTERN)
        return unless commit_id.is_a?(String) && commit_id.match?(UUID_PATTERN)
        return unless kind.is_a?(String) && latest_turn.is_a?(Integer) && latest_turn.positive?
        return unless message_count.is_a?(Integer) && message_count.positive?
        return unless [0, 1].include?(commit_slot)

        Time.iso8601(updated_at)
        {
          subagent_id:,
          conversation_id:,
          kind:,
          latest_turn:,
          updated_at:,
          message_count:,
          commit_id:,
          commit_slot:
        }
      rescue ArgumentError, TypeError
        nil
      end

      def mutable_copy(value)
        case value
        when Hash
          value.to_h { |key, child| [mutable_copy(key), mutable_copy(child)] }
        when Array
          value.map { |child| mutable_copy(child) }
        when String
          value.dup
        else
          value
        end
      end

      def encode_cursor(identity)
        Base64.urlsafe_encode64(
          JSON.generate([identity.updated_at.to_s, identity.subagent_id]),
          padding: false
        )
      end

      def decode_cursor(cursor)
        raise ToolError, "Invalid subagent list cursor" if String(cursor).bytesize > CURSOR_MAX_BYTES

        value = JSON.parse(Base64.urlsafe_decode64(String(cursor)))
        unless value.is_a?(Array) && value.length == 2 && value.all? { |part| part.is_a?(String) }
          raise ToolError, "Invalid subagent list cursor"
        end

        value
      rescue ArgumentError, JSON::ParserError
        raise ToolError, "Invalid subagent list cursor"
      end

      def reserve_identity(kind, task, task_name:)
        @mutex.synchronize do
          ensure_open!
          definition = @definitions[kind]
          raise ToolError, "Unknown subagent kind: #{kind}" unless definition

          return [nil, identity_capacity_response] if @identity_slots >= @max_identities

          rejection = reject_turn_locked(task)
          return [nil, rejection] if rejection

          subagent_id = agent_path(task_name)
          @identity_slots += 1
          @turn_count += 1
          @reserved_agent_paths[subagent_id] = true
          [definition, subagent_id]
        end
      end

      def agent_path(task_name)
        name = AgentPath.validate_name!(task_name)
        candidate = AgentPath.join(@parent_agent_path, name)
        if @identities.key?(candidate) || @reserved_agent_paths.key?(candidate)
          raise ToolError, "Agent path #{candidate.inspect} already exists; choose a different task_name."
        end
        candidate
      rescue ArgumentError => error
        raise ToolError, error.message
      end

      def release_identity_reservation(subagent_id)
        @mutex.synchronize do
          @reserved_agent_paths.delete(subagent_id)
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
        parent_operation_id: nil,
        context: nil
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
            parent_operation_id:,
            interrupts: [],
            interruption_metadata: context&.interruption_metadata,
            interruption_ids: context&.interruption_ids || []
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
                  identity.progress_sequence += 1
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
                  options[:conversation_id] = identity.conversation_id
                  options[:interruption_metadata] = turn.interruption_metadata
                  options[:interruption_ids] = turn.interruption_ids
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
          capture_activity(identity, turn, event)
          result = event.data[:result] if event.type == :invocation_stop
        end
        result
      end

      def capture_activity(identity, turn, event)
        return unless %i[tool_start tool_stop message_stop invocation_stop].include?(event.type)

        message = progress_message(event)
        tool_use = event.data[:tool_use]
        @mutex.synchronize do
          return unless identity.current.equal?(turn)

          identity.progress_message = message unless message.to_s.empty?
          identity.progress_sequence += 1
          @condition.broadcast
          if tool_use
            event_name = (event.type == :tool_start) ? "tool_started" : "tool_finished"
            emit(event_name, identity, turn:, tool_call_id: tool_use.id, tool_name: tool_use.name)
          else
            emit("activity", identity, turn:)
          end
        end
      end

      def progress_message(event)
        return unless event.type == :message_stop

        response = event.data[:response]
        return unless response&.stop_reason == :tool_use
        return unless response.message.role == :assistant
        return if response.message.content.grep(Content::ToolUse).empty?

        normalize_progress(response.message)
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
        persisted_response = response.is_a?(String) ? response : serialized_response

        interrupt_exchanges = @mutex.synchronize do
          while identity.durable && turn.interrupts.any? { |exchange| !exchange.complete } && !@closed
            @condition.wait(@mutex, CANCELLATION_POLL_INTERVAL)
          end
          if @closed
            turn.completion.resolve(cancelled_turn(identity, turn))
            next nil
          end

          identity.status = "persisting" if identity.durable
          turn.interrupts.select(&:complete).map { |exchange| [exchange.message, exchange.response] }
        end
        return unless interrupt_exchanges

        retain_agent_conversation(identity, turn, result, persisted_response, interrupt_exchanges)

        @mutex.synchronize do
          identity.latest_turn = turn.number
          identity.latest_response = response
          identity.latest_response_turn = turn.number
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

      def retain_agent_conversation(identity, turn, result, persisted_response, interrupt_exchanges)
        if identity.durable
          state = result.is_a?(RunResult) ? result.state : identity.state
          messages = [Message.new(role: :user, content: turn.message)]
          interrupt_exchanges.each do |message, response|
            messages << Message.new(role: :user, content: message)
            messages << Message.new(role: :assistant, content: response)
          end
          messages << Message.new(role: :assistant, content: persisted_response)
          identity.session.append(messages:, state:)
          message_count = identity.session.history.length
          persist_registry(identity, message_count:, state:)
          identity.committed_count = message_count
          project_conversation(identity, turn, messages)
        end
        if identity.agent.is_a?(Agent) && result.is_a?(RunResult)
          identity.history = result.messages.reject { |message| message.role == :system }.freeze
          identity.state = result.state
        end
      end

      def project_conversation(identity, turn, messages)
        identity.session.store.project_conversation(
          identity.session.id,
          messages:,
          actor_id: identity.session.actor_id,
          metadata: {
            "little_ghost_parent_link" => @parent_link,
            "little_ghost_conversation_id" => identity.conversation_id,
            "little_ghost_subagent_id" => identity.subagent_id,
            "little_ghost_kind" => identity.definition.kind,
            "little_ghost_turn" => turn.number
          }
        )
      rescue => error
        warn_failure("projection", identity.subagent_id, error)
      end

      def fail_turn(identity, turn, error, propagate: false)
        @mutex.synchronize do
          return if @closed && identity.status != "persisting"

          warn_failure("turn", identity.subagent_id, error)
          identity.latest_turn = turn.number
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
          identity.latest_turn = turn.number
          identity.progress_message = nil
          identity.current_turn = nil
          identity.current = nil
          identity.status = "cancelled"
          cancel_queued_turns(identity)
          emit("cancelled", identity, turn:) if newly_cancelled
          @condition.broadcast
        end
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
        if subagent_ids.nil?
          return @identities.values.reject { |identity| identity.resumed && identity.agent.nil? }
        end
        raise ToolError, "subagent_ids must be unique" if subagent_ids.uniq.length != subagent_ids.length

        subagent_ids.map do |subagent_id|
          identity = fetch_identity!(subagent_id)
          if identity.resumed && identity.agent.nil?
            raise ToolError, "Subagent #{subagent_id.inspect} is not active in this invocation."
          end
          identity
        end
      end

      def fetch_identity!(subagent_id)
        @identities.fetch(subagent_id) { raise ToolError, "Unknown subagent id: #{subagent_id}" }
      end

      def snapshot(identity, include_response: false, include_progress: false)
        value = {
          subagent_id: identity.subagent_id,
          conversation_id: identity.conversation_id,
          kind: identity.definition.kind,
          status: identity.status,
          current_turn: identity.current_turn,
          latest_turn: identity.latest_turn,
          queued_turns: identity.queue.length
        }
        value[:resumed] = true if identity.resumed
        if include_response && identity.latest_response
          if identity.status == "idle" && identity.latest_response_turn == identity.latest_turn
            value[:response] = identity.latest_response
            value[:response_turn] = identity.latest_response_turn
            value[:response_truncated] = true if identity.latest_response_truncated
          else
            value[:previous_response] = identity.latest_response
            value[:previous_response_turn] = identity.latest_response_turn
            value[:previous_response_truncated] = true if identity.latest_response_truncated
          end
        end
        if include_progress && identity.progress_sequence.positive? && %w[queued running].include?(identity.status)
          value[:progress] = {sequence: identity.progress_sequence}
          value[:progress][:message] = identity.progress_message if identity.progress_message
        end
        value[:error] = identity.latest_error if identity.latest_error
        value
      end

      def finished?(identity)
        %w[idle failed cancelled].include?(identity.status)
      end

      def emit(event, identity, turn: nil, **attributes)
        return unless @observer

        value = {
          event: event,
          subagent_id: identity.subagent_id,
          conversation_id: identity.conversation_id,
          resumed: identity.resumed,
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
        value.merge!(attributes)
        @observer.call(value.freeze)
      rescue
        nil
      end

      def observe_delegated_activity(identity)
        activity = identity.agent.respond_to?(:delegation_activity) && identity.agent.delegation_activity
        return unless activity

        activity.subscribe { record_delegated_activity(identity) }
      end

      def record_delegated_activity(identity)
        turn = @mutex.synchronize do
          next unless identity.status == "running" && identity.current

          identity.progress_sequence += 1
          @condition.broadcast
          identity.current
        end
        emit("activity", identity, turn:) if turn
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
