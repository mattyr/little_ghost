# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require_relative "../data_map"
require_relative "../session_store"

module LittleGhost
  module SessionStores
    # AgentCoreMemory keeps LittleGhost conversations in Amazon Bedrock AgentCore
    # Memory so they can resume across Ruby processes and deployments.
    #
    #   store = LittleGhost::SessionStores::AgentCoreMemory.new(
    #     memory_id: ENV.fetch("AGENTCORE_MEMORY_ID"),
    #     region: "us-east-1"
    #   )
    #
    # Configure the resulting store through Configuration#session_store; a
    # Runtime then owns its construction and lifetime. The optional
    # +aws-sdk-bedrockagentcore+ dependency is loaded only when a client is not
    # supplied.
    #
    # === Privacy and concurrency
    #
    # This store sends session data to Amazon Bedrock AgentCore Memory. For
    # stored transcripts and checkpoints, Session removes system messages,
    # transient messages, and private reasoning first. The remaining complete
    # message records may still contain personal data, visible text,
    # attachments, tool calls and results, and message metadata. Checkpoints
    # also send application state and session metadata.
    #
    # Conversation projection is a separate path. It removes private reasoning,
    # but sends visible text from every message the caller supplies, including
    # system or transient messages. Callers must filter projection input when
    # those messages should stay local. Projection also sends selected metadata.
    # None of this filtering anonymizes the remaining content.
    #
    # Use a memory, region, IAM policy, retention policy, and logging policy
    # approved for that data. Do not enable this store for content that is not
    # approved to leave the Ruby process.
    #
    # Session and actor identifiers become deterministic SHA-256 pseudonyms
    # before leaving the process. These values remain linkable, and low-entropy
    # identifiers may be recovered by dictionary matching. Treat them as
    # sensitive identifiers, not anonymous data.
    #
    # AgentCore's immutable event API requires one active writer for each
    # actor/session pair. This store serializes writers inside one Ruby process,
    # but horizontally scaled applications need an external lock or unique
    # active-run record. Commits use generation and checkpoint records so an
    # incomplete write is never exposed as a successful snapshot.
    #
    # AgentCore checkpoints are versioned. This store reads supported historical
    # versions without writing during #load, then writes the current checkpoint
    # format when the session next appends or replaces its snapshot.
    class AgentCoreMemory < SessionStore
      MESSAGE_PREFIX = "little_ghost:message:v4:" # :nodoc:
      MESSAGE_CHUNK_PREFIX = "little_ghost:message_chunk:v4:" # :nodoc:
      CHECKPOINT_PREFIX = "little_ghost:checkpoint:v5:" # :nodoc:
      LEGACY_CHECKPOINT_PREFIX = "little_ghost:checkpoint:v4:" # :nodoc:
      CONVERSATIONAL_TEXT_LIMIT = 100_000 # :nodoc:
      MESSAGE_CHUNK_CONTENT_LIMIT = 90_000 # :nodoc:
      EVENT_PAYLOAD_LIMIT = 100 # :nodoc:
      MESSAGE_CHUNK_COUNT_LIMIT = 10_000 # :nodoc:
      EVENT_TYPE_METADATA_KEY = "little_ghost_type" # :nodoc:
      GENERATION_METADATA_KEY = "little_ghost_generation" # :nodoc:
      COMMIT_METADATA_KEY = "little_ghost_commit" # :nodoc:
      SYMBOL_KEY_PREFIX = "little_ghost:symbol:" # :nodoc:
      STRING_KEY_PREFIX = "little_ghost:string:" # :nodoc:
      MESSAGE_EVENT_TYPE = "message_v4" # :nodoc:
      CHECKPOINT_EVENT_TYPE = "checkpoint_v5" # :nodoc:
      LEGACY_CHECKPOINT_EVENT_TYPE = "checkpoint_v4" # :nodoc:
      CONVERSATION_PROJECTION_EVENT_TYPE = "conversation_projection_v1" # :nodoc:
      PROJECTION_METADATA_KEYS = %w[
        little_ghost_parent_link
        little_ghost_conversation_id
        little_ghost_subagent_id
        little_ghost_kind
        little_ghost_turn
      ].freeze # :nodoc:
      # AgentCore's SDK timestamp transport cannot preserve sub-second ordering.
      EVENT_TIMESTAMP_INCREMENT = 1 # :nodoc:
      LIST_PAGE_SIZE = 100 # :nodoc:
      MAX_LIST_PAGES = 1_000 # :nodoc:
      MAX_CHECKPOINT_EVENTS = 10_000 # :nodoc:
      MAX_GENERATION_EVENTS = 10_000 # :nodoc:
      MAX_GENERATION_PAYLOADS = 25_000 # :nodoc:
      MAX_EVENT_SERIALIZED_BYTES = 10 * 1024 * 1024 # :nodoc:
      MAX_CHECKPOINT_READ_BYTES = 64 * 1024 * 1024 # :nodoc:
      MAX_SESSION_SERIALIZED_BYTES = 128 * 1024 * 1024 # :nodoc:
      MAX_MESSAGE_SERIALIZED_BYTES = 16 * 1024 * 1024 # :nodoc:
      MAX_CHECKPOINT_SERIALIZED_BYTES = 1 * 1024 * 1024 # :nodoc:
      MAX_SESSION_MESSAGES = 10_000 # :nodoc:
      MAX_REVISION = (2**63) - 1 # :nodoc:

      # Produces a stable AgentCore-safe pseudonym. This is not anonymization.
      def self.safe_id(value)
        "lg_#{Digest::SHA256.hexdigest(String(value))}"
      end

      # Supply +client+ for explicit dependency
      # injection, or +region+ and an optional +client_factory+ for lazy refresh.
      def initialize(
        memory_id:,
        client: nil,
        client_factory: nil,
        region: nil,
        clock: -> { Time.now }
      )
        super()
        @memory_id = String(memory_id)
        raise ArgumentError, "memory_id must not be empty" if @memory_id.empty?

        @region = region
        @client_factory = client_factory || -> { build_client(@region) }
        @client = client || @client_factory.call
        @clock = clock
        @operation_context_key = :"little_ghost_session_store_operation_#{object_id}"
        @client_mutex = Mutex.new
        @client_condition = ConditionVariable.new
        @client_refreshing = false
        @client_refresh_generation = 0
        @client_refresh_failure = nil
        @persistence_locks = {}
        @persistence_locks_mutex = Mutex.new
      end

      # Loads the latest committed generation for the required actor and session.
      def load(id, actor_id: nil)
        actor = self.class.safe_id(required_actor_id(actor_id))
        session = self.class.safe_id(id)
        head, lineage = latest_checkpoint(actor, session)
        return unless head

        checkpoint = head.fetch(:checkpoint)
        records = message_records_for(actor, session, lineage:)
        {
          messages: messages_from(records, lineage:),
          state: checkpoint.fetch(:state),
          metadata: checkpoint.fetch(:metadata)
        }
      end

      # Appends sanitized messages as a new committed checkpoint when
      # +expected_count+ matches the latest remote generation.
      def append(id, messages:, state:, metadata:, expected_count:, actor_id: nil)
        messages = persistable_messages(messages)
        state = DataMap.new(state).to_h
        metadata = DataMap.new(metadata).to_h
        actor = self.class.safe_id(required_actor_id(actor_id))
        session = self.class.safe_id(id)
        key = [actor, session]
        synchronize_persistence(key) do
          head, lineage = latest_checkpoint(actor, session)
          persistence = head&.fetch(:checkpoint)
          persisted_count = persistence&.fetch(:message_count, 0) || 0
          unless persisted_count == expected_count
            raise ProtocolError, "Session changed while it was being updated"
          end

          if head && head.fetch(:format) != CHECKPOINT_EVENT_TYPE
            existing = messages_from(message_records_for(actor, session, lineage:), lineage:)
            messages = [*existing, *messages].freeze
            expected_count = 0
            persistence = head.fetch(:checkpoint)
            root = true
            generation = SecureRandom.uuid
          else
            root = persistence.nil?
            generation = persistence&.fetch(:generation) || SecureRandom.uuid
          end
          commit_id = SecureRandom.uuid
          plan = plan_messages(messages, generation:, commit_id:, offset: expected_count)
          checkpoint = build_checkpoint(
            persistence:,
            generation:,
            commit_id:,
            root:,
            plan:,
            message_count: root ? messages.length : expected_count + messages.length,
            state:,
            metadata:
          )
          persist_commit(actor, session, plan:, checkpoint:, previous_timestamp: head&.fetch(:event_timestamp))
        end
        {messages:, state:, metadata:}
      end

      # Replaces the visible snapshot by committing a new remote generation.
      def replace(id, messages:, state:, metadata:, actor_id: nil)
        messages = persistable_messages(messages)
        state = DataMap.new(state).to_h
        metadata = DataMap.new(metadata).to_h
        actor = self.class.safe_id(required_actor_id(actor_id))
        session = self.class.safe_id(id)
        key = [actor, session]
        synchronize_persistence(key) do
          head, = latest_checkpoint(actor, session)
          persistence = head&.fetch(:checkpoint)
          generation = SecureRandom.uuid
          commit_id = SecureRandom.uuid
          plan = plan_messages(messages, generation:, commit_id:, offset: 0)
          checkpoint = build_checkpoint(
            persistence:,
            generation:,
            commit_id:,
            root: true,
            plan:,
            message_count: messages.length,
            state:,
            metadata:
          )
          persist_commit(actor, session, plan:, checkpoint:, previous_timestamp: head&.fetch(:event_timestamp))
        end
        {messages:, state:, metadata:}
      end

      # Writes visible conversational text for AgentCore Memory extraction
      # without changing LittleGhost's stored session transcript. This removes
      # private reasoning, but does not remove system or transient messages;
      # callers must omit any message whose visible text should stay local.
      def project_conversation(id, messages:, metadata:, actor_id: nil)
        payload = persistable_messages(messages).filter_map do |message|
          text = message.text
          next if text.empty?

          conversational_payload(text, message.role)
        end
        return if payload.empty?

        event_metadata = {
          EVENT_TYPE_METADATA_KEY => {string_value: CONVERSATION_PROJECTION_EVENT_TYPE}
        }
        PROJECTION_METADATA_KEYS.each do |key|
          value = metadata[key] || metadata[key.to_sym]
          event_metadata[key] = {string_value: value.to_s} unless value.nil?
        end
        agent_core_call(
          :create_event,
          memory_id: @memory_id,
          actor_id: self.class.safe_id(required_actor_id(actor_id)),
          session_id: self.class.safe_id(id),
          event_timestamp: next_event_timestamp(nil),
          payload:,
          metadata: event_metadata,
          extraction_mode: "SKIP"
        )
      end

      # Parents AgentCore telemetry emitted in the block to +operation_id+.
      def with_operation_context(operation_id)
        ExecutionState.with(@operation_context_key => operation_id) { yield }
      end

      private

      def synchronize_persistence(key)
        entry = @persistence_locks_mutex.synchronize do
          current = (@persistence_locks[key] ||= [Mutex.new, 0])
          current[1] += 1
          current
        end
        entry.first.synchronize { yield }
      ensure
        if entry
          @persistence_locks_mutex.synchronize do
            entry[1] -= 1
            @persistence_locks.delete(key) if entry[1].zero?
          end
        end
      end

      def build_client(region)
        require "aws-sdk-bedrockagentcore"
        Aws::BedrockAgentCore::Client.new(**({region:} if region))
      rescue LoadError
        raise ConfigurationError, "AgentCore Memory requires the optional aws-sdk-bedrockagentcore gem"
      end

      def agent_core_call(operation, **parameters)
        retries = 0
        refreshes = 0

        with_memory_span(operation) do |telemetry|
          client = current_client
          result = client.public_send(operation, **parameters)
          record_memory_outcome(telemetry, retries:, refreshes:, client:)
          result
        rescue => error
          unless expired_token?(error) && retries.zero?
            record_memory_failure(telemetry, error, retries:, refreshes:)
            raise
          end

          retries += 1
          refreshed = refresh_client(client)
          refreshes += 1 if refreshed
          record_client_refresh(operation, error, retry_count: retries, refreshed:)
          retry
        end
      end

      def current_client
        @client_mutex.synchronize { @client }
      end

      def refresh_client(previous_client)
        loop do
          state, value = @client_mutex.synchronize do
            if !@client.equal?(previous_client)
              [:installed, false]
            elsif @client_refreshing
              generation = @client_refresh_generation
              @client_condition.wait(@client_mutex, 0.01)
              if @client_refresh_failure&.first == generation
                [:failure, @client_refresh_failure.last]
              else
                [:retry, nil]
              end
            else
              @client_refreshing = true
              @client_refresh_generation += 1
              [:owner, @client_refresh_generation]
            end
          end
          return value if state == :installed
          raise value if state == :failure
          next if state == :retry

          return build_replacement_client(value, previous_client)
        end
      end

      def build_replacement_client(generation, previous_client)
        replacement = @client_factory.call
        @client_mutex.synchronize do
          if @client.equal?(previous_client)
            @client = replacement
            @client_refresh_failure = nil
            true
          else
            false
          end
        end
      rescue => error
        @client_mutex.synchronize { @client_refresh_failure = [generation, error] }
        raise
      ensure
        @client_mutex.synchronize do
          @client_refreshing = false
          @client_condition.broadcast
        end
      end

      def expired_token?(error)
        defined?(Aws::BedrockAgentCore::Errors::ExpiredTokenException) &&
          error.instance_of?(Aws::BedrockAgentCore::Errors::ExpiredTokenException)
      end

      def with_memory_span(operation)
        payload = {
          operation_id: SecureRandom.uuid,
          parent: ExecutionState[@operation_context_key],
          span_name: "BedrockAgentCore/#{operation}"
        }.merge(
          "cloud.provider" => "aws",
          "rpc.method" => operation.to_s,
          "rpc.service" => "BedrockAgentCore",
          "rpc.system" => "aws-api"
        )
        payload["cloud.region"] = @region.to_s if @region
        Instrumentation.instrument(:session_store, payload) { |telemetry| yield telemetry }
      end

      def record_memory_outcome(telemetry, retries:, refreshes:, client:)
        telemetry["little_ghost.session_store.retry_count"] = retries
        telemetry["little_ghost.session_store.client_refresh_count"] = refreshes
        telemetry["little_ghost.session_store.recovered"] = retries.positive?
        seconds = credential_seconds_to_expiry(client)
        telemetry["little_ghost.session_store.credential_seconds_to_expiry"] = seconds if seconds
      end

      def record_memory_failure(telemetry, error, retries:, refreshes:)
        telemetry["little_ghost.session_store.retry_count"] = retries
        telemetry["little_ghost.session_store.client_refresh_count"] = refreshes
        telemetry[:error_type] = error.class.name
      end

      def record_client_refresh(operation, error, retry_count:, refreshed:)
        Events.warn(
          "little_ghost.session_store.client_refresh",
          operation:,
          error_type: error.class.name,
          retry_count:,
          refreshed:
        )
      rescue
        nil
      end

      def credential_seconds_to_expiry(client)
        credentials = client.config.credentials
        expiration = credentials.expiration if credentials.respond_to?(:expiration)
        return unless expiration.respond_to?(:to_time)

        [(expiration.to_time - @clock.call).round, 0].max
      rescue
        nil
      end

      def latest_checkpoint(actor_id, session_id)
        entries = checkpoint_entries(actor_id, session_id)
        return [nil, []] if entries.empty?

        by_commit = entries.each_with_object({}) do |entry, index|
          commit_id = entry.dig(:checkpoint, :commit_id)
          existing = index[commit_id]
          if existing && existing.fetch(:checkpoint) != entry.fetch(:checkpoint)
            raise ProtocolError, "AgentCore session contains conflicting checkpoint events"
          end

          if existing.nil? || entry.fetch(:event_timestamp) > existing.fetch(:event_timestamp)
            index[commit_id] = entry
          end
        end
        viable = viable_checkpoint_graph(by_commit)
        return [nil, []] if viable.empty?

        head = viable.values.max_by do |entry|
          checkpoint = entry.fetch(:checkpoint)
          [
            checkpoint.fetch(:generation_revision),
            checkpoint.fetch(:generation),
            checkpoint.fetch(:revision),
            checkpoint.fetch(:root) ? 1 : 0,
            entry.fetch(:event_timestamp).to_i,
            checkpoint.fetch(:commit_id)
          ]
        end
        [head, checkpoint_lineage(head, viable)]
      end

      def checkpoint_entries(actor_id, session_id)
        entries = []
        [LEGACY_CHECKPOINT_EVENT_TYPE, CHECKPOINT_EVENT_TYPE].each do |format|
          each_event(
            actor_id,
            session_id,
            filter: metadata_filter(type: format),
            event_limit: MAX_CHECKPOINT_EVENTS,
            payload_limit: MAX_CHECKPOINT_EVENTS,
            byte_limit: MAX_CHECKPOINT_READ_BYTES
          ) do |event|
            data = event_session_data(event, format:)
            raise ProtocolError, "AgentCore session checkpoint event is invalid" unless data
            unless event.event_timestamp.is_a?(Time)
              raise ProtocolError, "AgentCore session checkpoint timestamp is invalid"
            end

            checkpoint = normalize_checkpoint(data, format:)
            unless event_metadata_value(event, GENERATION_METADATA_KEY) == checkpoint.fetch(:generation) &&
                event_metadata_value(event, COMMIT_METADATA_KEY) == checkpoint.fetch(:commit_id)
              raise ProtocolError, "AgentCore session checkpoint metadata is invalid"
            end

            entries << {checkpoint:, event_timestamp: event.event_timestamp, format:}.freeze
          end
        end
        entries
      end

      def viable_checkpoint_graph(by_commit)
        viable = {}
        by_commit.each_value.sort_by { |entry| entry.dig(:checkpoint, :revision) }.each do |entry|
          checkpoint = entry.fetch(:checkpoint)
          parent = checkpoint[:parent_commit_id] && by_commit[checkpoint.fetch(:parent_commit_id)]
          if checkpoint.fetch(:root)
            validate_root_checkpoint!(checkpoint, parent)
            viable[checkpoint.fetch(:commit_id)] = entry
          elsif parent
            validate_append_checkpoint!(checkpoint, parent.fetch(:checkpoint))
            viable[checkpoint.fetch(:commit_id)] = entry if viable.key?(checkpoint.fetch(:parent_commit_id))
          end
        end

        viable
      end

      def validate_root_checkpoint!(checkpoint, parent)
        has_valid_origin = if checkpoint[:parent_commit_id].nil?
          checkpoint.fetch(:revision) == 1
        elsif parent
          checkpoint.fetch(:revision) == parent.dig(:checkpoint, :revision) + 1 &&
            checkpoint.fetch(:generation) != parent.dig(:checkpoint, :generation)
        else
          checkpoint.fetch(:revision) > 1
        end
        unless has_valid_origin && checkpoint.fetch(:generation_revision) == checkpoint.fetch(:revision) &&
            checkpoint.fetch(:start_sequence).zero? &&
            checkpoint.fetch(:added_count) == checkpoint.fetch(:message_count)
          raise ProtocolError, "AgentCore session root checkpoint is invalid"
        end
      end

      def validate_append_checkpoint!(checkpoint, parent)
        valid = checkpoint.fetch(:generation) == parent.fetch(:generation) &&
          checkpoint.fetch(:generation_revision) == parent.fetch(:generation_revision) &&
          checkpoint.fetch(:revision) == parent.fetch(:revision) + 1 &&
          checkpoint.fetch(:start_sequence) == parent.fetch(:message_count) &&
          checkpoint.fetch(:message_count) == parent.fetch(:message_count) + checkpoint.fetch(:added_count) &&
          checkpoint.fetch(:serialized_bytes) >= parent.fetch(:serialized_bytes) &&
          checkpoint.fetch(:event_count) >= parent.fetch(:event_count) &&
          checkpoint.fetch(:payload_count) >= parent.fetch(:payload_count)
        raise ProtocolError, "AgentCore session append checkpoint is invalid" unless valid
      end

      def checkpoint_lineage(head, by_commit)
        lineage = []
        current = head
        loop do
          checkpoint = current.fetch(:checkpoint)
          lineage << checkpoint
          break if checkpoint.fetch(:root)

          current = by_commit.fetch(checkpoint.fetch(:parent_commit_id))
        end
        lineage.reverse.freeze
      end

      def each_event(actor_id, session_id, filter:, event_limit:, payload_limit:, byte_limit:)
        token = nil
        tokens = {}
        page_count = 0
        event_count = 0
        payload_count = 0
        bytes = 0
        loop do
          page_count += 1
          raise ProtocolError, "AgentCore session exceeds the page limit" if page_count > MAX_LIST_PAGES

          response = agent_core_call(
            :list_events,
            memory_id: @memory_id,
            actor_id:,
            session_id:,
            include_payloads: true,
            filter:,
            max_results: LIST_PAGE_SIZE,
            **(token ? {next_token: token} : {})
          )
          events = Array(response.events)
          raise ProtocolError, "AgentCore returned too many events in one page" if events.length > LIST_PAGE_SIZE

          events.each do |event|
            event_count += 1
            raise ProtocolError, "AgentCore session exceeds the event limit" if event_count > event_limit

            payloads = event_payloads(event)
            payload_count += payloads.length
            raise ProtocolError, "AgentCore session exceeds the payload limit" if payload_count > payload_limit

            event_bytes = payloads.sum { |payload| payload_bytes(payload) }
            if event_bytes > MAX_EVENT_SERIALIZED_BYTES
              raise ProtocolError, "AgentCore session event exceeds the byte limit"
            end
            bytes += event_bytes
            raise ProtocolError, "AgentCore session exceeds the byte limit" if bytes > byte_limit

            yield event
          end
          token = response.next_token
          break unless token

          raise ProtocolError, "AgentCore returned a repeated pagination token" if tokens[token]
          tokens[token] = true
        end
      end

      def message_records_for(actor_id, session_id, lineage:)
        expectations = commit_expectations(lineage)
        metrics = expectations.to_h { |commit_id, _| [commit_id, {events: 0, payloads: 0, bytes: 0}] }
        records = []
        chunks = {}
        generation = lineage.last.fetch(:generation)
        each_event(
          actor_id,
          session_id,
          filter: metadata_filter(type: MESSAGE_EVENT_TYPE, generation:),
          event_limit: MAX_GENERATION_EVENTS,
          payload_limit: MAX_GENERATION_PAYLOADS,
          byte_limit: MAX_SESSION_SERIALIZED_BYTES
        ) do |event|
          event_generation = event_metadata_value(event, GENERATION_METADATA_KEY)
          unless event_generation == generation
            raise ProtocolError, "AgentCore session message generation is invalid"
          end

          commit_id = event_metadata_value(event, COMMIT_METADATA_KEY)
          next unless expectations.key?(commit_id)

          event_payloads(event).each do |payload|
            conversational = payload.respond_to?(:conversational) ? payload.conversational : nil
            raise ProtocolError, "AgentCore session message event is invalid" unless conversational

            text = conversational_text(payload)
            record = if text.start_with?(MESSAGE_PREFIX)
              decoded = decode_message_record(text.delete_prefix(MESSAGE_PREFIX))
              validate_message_record!(decoded, generation:, commit_id:)
              decoded
            elsif text.start_with?(MESSAGE_CHUNK_PREFIX)
              record_message_chunk(text, chunks, commit_id:)
              nil
            else
              raise ProtocolError, "AgentCore session message is not a LittleGhost event"
            end
            records << record if record
            metrics.fetch(commit_id)[:payloads] += 1
            metrics.fetch(commit_id)[:bytes] += text.bytesize
          end
          metrics.fetch(commit_id)[:events] += 1
        end
        chunks.each_value do |entry|
          next unless expectations.key?(entry.fetch(:commit_id))

          record = decode_message_chunks(entry)
          raise ProtocolError, "AgentCore session message chunks are incomplete" unless record

          validate_message_record!(record, generation:, commit_id: entry.fetch(:commit_id))
          records << record
        end
        validate_commit_metrics!(expectations, metrics)
        records
      end

      def commit_expectations(lineage)
        previous = nil
        lineage.to_h do |checkpoint|
          expected = {
            start: checkpoint.fetch(:start_sequence),
            count: checkpoint.fetch(:added_count),
            bytes: checkpoint.fetch(:serialized_bytes) - (previous&.fetch(:serialized_bytes) || 0),
            events: checkpoint.fetch(:event_count) - (previous&.fetch(:event_count) || 0),
            payloads: checkpoint.fetch(:payload_count) - (previous&.fetch(:payload_count) || 0)
          }.freeze
          previous = checkpoint
          [checkpoint.fetch(:commit_id), expected]
        end
      end

      def validate_commit_metrics!(expectations, metrics)
        expectations.each do |commit_id, expected|
          actual = metrics.fetch(commit_id)
          unless actual.fetch(:events) == expected.fetch(:events) &&
              actual.fetch(:payloads) == expected.fetch(:payloads) &&
              actual.fetch(:bytes) == expected.fetch(:bytes)
            raise ProtocolError, "AgentCore session checkpoint payload accounting is invalid"
          end
        end
      end

      def metadata_filter(type:, generation: nil)
        values = {EVENT_TYPE_METADATA_KEY => type}
        values[GENERATION_METADATA_KEY] = generation if generation
        {event_metadata: values.map do |key, value|
          {
            left: {metadata_key: key},
            operator: "EQUALS_TO",
            right: {metadata_value: {string_value: value}}
          }
        end}
      end

      def event_payloads(event)
        payloads = event.respond_to?(:payload) ? event.payload : nil
        unless payloads.is_a?(Array) && payloads.length.between?(1, EVENT_PAYLOAD_LIMIT)
          raise ProtocolError, "AgentCore session event payload is invalid"
        end

        payloads
      end

      def payload_bytes(payload)
        conversational = payload.respond_to?(:conversational) ? payload.conversational : nil
        return conversational_text(payload).bytesize if conversational

        blob = payload.respond_to?(:blob) ? payload.blob : nil
        return blob.bytesize if blob.is_a?(String)

        raise ProtocolError, "AgentCore session event payload is invalid"
      rescue JSON::GeneratorError, TypeError => error
        raise ProtocolError, "AgentCore session event payload is invalid: #{error.class}"
      end

      def event_metadata_value(event, key)
        metadata = event.respond_to?(:metadata) ? event.metadata : nil
        value = metadata&.[](key) || metadata&.[](key.to_sym)
        value = value.string_value if value.respond_to?(:string_value)
        value = value[:string_value] || value["string_value"] if value.is_a?(Hash)
        unless value.is_a?(String) && !value.empty?
          raise ProtocolError, "AgentCore session event metadata is invalid"
        end

        value
      end

      def messages_from(records, lineage:)
        expected = {}
        commit_expectations(lineage).each do |commit_id, range|
          range.fetch(:count).times do |offset|
            expected[range.fetch(:start) + offset] = commit_id
          end
        end
        indexed = {}
        records.each do |record|
          sequence = record.fetch(:sequence)
          commit_id = record.fetch(:commit_id)
          unless expected[sequence] == commit_id
            raise ProtocolError, "AgentCore session contains a message outside its committed range"
          end

          existing = indexed[sequence]
          if existing && existing.to_h != record.fetch(:message).to_h
            raise ProtocolError, "AgentCore session contains conflicting message events"
          end
          indexed[sequence] = record.fetch(:message)
        end
        unless indexed.length == expected.length && indexed.keys.all? { |sequence| expected.key?(sequence) }
          raise ProtocolError, "AgentCore session checkpoint is incomplete"
        end

        expected.length.times.map { |sequence| indexed.fetch(sequence) }
      end

      def event_session_data(event, format:)
        prefix = (format == LEGACY_CHECKPOINT_EVENT_TYPE) ? LEGACY_CHECKPOINT_PREFIX : CHECKPOINT_PREFIX
        values = event_payloads(event).filter_map do |payload|
          blob = payload.respond_to?(:blob) ? payload.blob : nil
          next unless blob.is_a?(String) && blob.start_with?(prefix)

          checkpoint = deserialize_checkpoint(blob.delete_prefix(prefix), format:)
          checkpoint if checkpoint.is_a?(Hash)
        end
        values.one? ? values.first : nil
      rescue JSON::ParserError
        nil
      end

      def plan_messages(messages, generation:, commit_id:, offset:)
        payloads = []
        payload_count = 0
        serialized_bytes = 0
        messages.each.with_index(offset) do |message, sequence|
          serialized = serialize_message(generation:, commit_id:, sequence:, message:)
          texts = message_texts(serialized, commit_id:, sequence:)
          payloads.concat(texts.map { |text| {role: message.role, text:}.freeze })
          payload_count += texts.length
          serialized_bytes += texts.sum(&:bytesize)
        end
        events = pack_message_payloads(payloads)
        {
          events: events.freeze,
          event_count: events.length,
          payload_count:,
          serialized_bytes:
        }.freeze
      end

      def message_texts(serialized, commit_id:, sequence:)
        text = "#{MESSAGE_PREFIX}#{serialized}"
        return [text].freeze if text.length <= CONVERSATIONAL_TEXT_LIMIT

        chunks = split_by_characters(serialized, MESSAGE_CHUNK_CONTENT_LIMIT)
        if chunks.length > MESSAGE_CHUNK_COUNT_LIMIT
          raise ProtocolError, "AgentCore session message exceeds the chunk limit"
        end
        total = chunks.length
        chunks.map.with_index do |content, index|
          framed = "#{MESSAGE_CHUNK_PREFIX}#{commit_id}:#{sequence}:#{index}:#{total}:#{content}"
          if framed.length > CONVERSATIONAL_TEXT_LIMIT
            raise ProtocolError, "AgentCore session message chunk exceeds the character limit"
          end
          framed
        end.freeze
      end

      def split_by_characters(text, limit)
        text.scan(Regexp.new(".{1,#{Integer(limit)}}", Regexp::MULTILINE))
      end

      def pack_message_payloads(payloads)
        events = []
        current = []
        current_bytes = 0
        payloads.each do |payload|
          bytes = payload.fetch(:text).bytesize
          if bytes > MAX_EVENT_SERIALIZED_BYTES
            raise ProtocolError, "AgentCore session event exceeds the byte limit"
          end
          if current.any? &&
              (current.length >= EVENT_PAYLOAD_LIMIT || current_bytes + bytes > MAX_EVENT_SERIALIZED_BYTES)
            events << current.freeze
            current = []
            current_bytes = 0
          end
          current << payload
          current_bytes += bytes
        end
        events << current.freeze if current.any?
        events.freeze
      end

      def build_checkpoint(persistence:, generation:, commit_id:, root:, plan:, message_count:, state:, metadata:)
        base = root ? nil : persistence
        revision = (persistence&.fetch(:revision) || 0) + 1
        checkpoint = {
          "generation" => generation,
          "generation_revision" => root ? revision : persistence.fetch(:generation_revision),
          "commit_id" => commit_id,
          "parent_commit_id" => persistence&.fetch(:commit_id),
          "revision" => revision,
          "root" => root,
          "start_sequence" => root ? 0 : persistence.fetch(:message_count),
          "added_count" => root ? message_count : message_count - persistence.fetch(:message_count),
          "message_count" => message_count,
          "serialized_bytes" => (base&.fetch(:serialized_bytes) || 0) + plan.fetch(:serialized_bytes),
          "event_count" => (base&.fetch(:event_count) || 0) + plan.fetch(:event_count),
          "payload_count" => (base&.fetch(:payload_count) || 0) + plan.fetch(:payload_count),
          "state" => state,
          "metadata" => metadata
        }
        validate_session_size!(
          checkpoint.fetch("message_count"),
          checkpoint.fetch("serialized_bytes"),
          event_count: checkpoint.fetch("event_count"),
          payload_count: checkpoint.fetch("payload_count")
        )
        if checkpoint.fetch("revision") > MAX_REVISION ||
            serialize_checkpoint(checkpoint).bytesize > MAX_CHECKPOINT_SERIALIZED_BYTES
          raise ProtocolError, "AgentCore session checkpoint exceeds the byte limit"
        end
        checkpoint.freeze
      rescue JSON::GeneratorError, TypeError => error
        raise ProtocolError, "AgentCore session checkpoint could not be serialized: #{error.class}"
      end

      def persist_commit(actor_id, session_id, plan:, checkpoint:, previous_timestamp:)
        timestamp = previous_timestamp
        plan.fetch(:events).each do |event|
          timestamp = create_message_event(
            actor_id,
            session_id,
            event,
            generation: checkpoint.fetch("generation"),
            commit_id: checkpoint.fetch("commit_id"),
            previous_timestamp: timestamp
          )
        end
        create_session_event(actor_id, session_id, checkpoint:, previous_timestamp: timestamp)
      end

      def create_message_event(actor_id, session_id, event, generation:, commit_id:, previous_timestamp:)
        timestamp = next_event_timestamp(previous_timestamp)
        agent_core_call(
          :create_event,
          memory_id: @memory_id,
          actor_id:,
          session_id:,
          event_timestamp: timestamp,
          payload: event.map do |message_payload|
            conversational_payload(message_payload.fetch(:text), message_payload.fetch(:role))
          end,
          metadata: event_metadata(MESSAGE_EVENT_TYPE, generation, commit_id),
          extraction_mode: "SKIP"
        )
        timestamp
      end

      def conversational_payload(text, role)
        {conversational: {
          content: {text:},
          role: role_to_agent_core(role)
        }}
      end

      def create_session_event(actor_id, session_id, checkpoint:, previous_timestamp:)
        timestamp = next_event_timestamp(previous_timestamp)
        agent_core_call(
          :create_event,
          memory_id: @memory_id,
          actor_id:,
          session_id:,
          event_timestamp: timestamp,
          payload: [{blob: "#{CHECKPOINT_PREFIX}#{serialize_checkpoint(checkpoint)}"}],
          metadata: event_metadata(
            CHECKPOINT_EVENT_TYPE,
            checkpoint.fetch("generation"),
            checkpoint.fetch("commit_id")
          )
        )
        timestamp
      end

      def event_metadata(type, generation, commit_id)
        {
          EVENT_TYPE_METADATA_KEY => {string_value: type},
          GENERATION_METADATA_KEY => {string_value: generation},
          COMMIT_METADATA_KEY => {string_value: commit_id}
        }
      end

      def serialize_message(generation:, commit_id:, sequence:, message:)
        serialized = JSON.generate(generation:, commit_id:, sequence:, message: message.to_h)
        if serialized.bytesize > MAX_MESSAGE_SERIALIZED_BYTES
          raise ProtocolError, "AgentCore session message exceeds the byte limit"
        end

        serialized
      rescue JSON::GeneratorError, TypeError => error
        raise ProtocolError, "AgentCore session message could not be serialized: #{error.class}"
      end

      def serialize_checkpoint(checkpoint)
        JSON.generate(checkpoint)
      end

      def deserialize_checkpoint(value, format: CHECKPOINT_EVENT_TYPE)
        document = JSON.parse(value)
        return document unless document.is_a?(Hash)

        if format == LEGACY_CHECKPOINT_EVENT_TYPE
          document["state"] = decode_legacy_hash_keys(document.fetch("state", {}))
          document["metadata"] = decode_legacy_hash_keys(document.fetch("metadata", {}))
        end
        document
      end

      def decode_legacy_hash_keys(value)
        case value
        when Hash
          value.to_h do |key, child|
            decoded_key = if key.start_with?(SYMBOL_KEY_PREFIX)
              key.delete_prefix(SYMBOL_KEY_PREFIX).to_sym
            else
              key.delete_prefix(STRING_KEY_PREFIX)
            end
            [decoded_key, decode_legacy_hash_keys(child)]
          end
        when Array
          value.map { |child| decode_legacy_hash_keys(child) }
        else
          value
        end
      end

      def validate_session_size!(message_count, serialized_bytes, event_count: 0, payload_count: 0)
        if message_count > MAX_SESSION_MESSAGES
          raise ProtocolError, "AgentCore session exceeds the message limit"
        end
        if serialized_bytes > MAX_SESSION_SERIALIZED_BYTES
          raise ProtocolError, "AgentCore session exceeds the byte limit"
        end
        if event_count > MAX_GENERATION_EVENTS
          raise ProtocolError, "AgentCore session exceeds the event limit"
        end
        if payload_count > MAX_GENERATION_PAYLOADS
          raise ProtocolError, "AgentCore session exceeds the payload limit"
        end
      end

      def decode_message_record(value)
        data = JSON.parse(value)
        raise ArgumentError unless data.is_a?(Hash)

        generation = data.fetch("generation")
        commit_id = data.fetch("commit_id")
        sequence = data.fetch("sequence")
        message_data = data.fetch("message")
        raise ArgumentError unless message_data.is_a?(Hash)

        message = Message.coerce(message_data)
        unless valid_identifier?(generation) && valid_identifier?(commit_id) &&
            sequence.is_a?(Integer) && sequence >= 0
          raise ArgumentError
        end

        {generation:, commit_id:, sequence:, message:}.freeze
      rescue JSON::ParserError, KeyError, NoMethodError, ArgumentError, TypeError => error
        raise ProtocolError, "AgentCore session message is invalid: #{error.class}"
      end

      def record_message_chunk(text, chunks, commit_id:)
        framed_commit_id, sequence, index, total, content = text.delete_prefix(MESSAGE_CHUNK_PREFIX).split(":", 5)
        sequence = Integer(sequence)
        index = Integer(index)
        total = Integer(total)
        unless framed_commit_id == commit_id && valid_identifier?(framed_commit_id) && sequence >= 0 &&
            total.between?(1, MESSAGE_CHUNK_COUNT_LIMIT) &&
            index.between?(0, total - 1) && content
          raise ProtocolError, "AgentCore session message chunk is invalid"
        end

        key = [framed_commit_id, sequence]
        entry = chunks[key]
        entry ||= chunks[key] = {commit_id: framed_commit_id, sequence:, total:, bytes: 0, parts: {}}
        if entry.fetch(:total) != total || entry.fetch(:parts).key?(index)
          raise ProtocolError, "AgentCore session message chunk is invalid"
        end
        entry[:bytes] += content.bytesize
        if entry.fetch(:bytes) > MAX_MESSAGE_SERIALIZED_BYTES
          raise ProtocolError, "AgentCore session message exceeds the byte limit"
        end
        entry.fetch(:parts)[index] = content
      rescue ArgumentError, TypeError
        raise ProtocolError, "AgentCore session message chunk is invalid"
      end

      def decode_message_chunks(entry)
        total = entry.fetch(:total)
        parts = entry.fetch(:parts)
        return unless parts.length == total

        record = decode_message_record(total.times.map { |index| parts.fetch(index) }.join)
        unless record.fetch(:commit_id) == entry.fetch(:commit_id) && record.fetch(:sequence) == entry.fetch(:sequence)
          raise ProtocolError, "AgentCore session message chunk is invalid"
        end
        record
      rescue JSON::ParserError, KeyError, ArgumentError => error
        raise ProtocolError, "AgentCore session message is invalid: #{error.class}"
      end

      def validate_message_record!(record, generation:, commit_id:)
        unless record.fetch(:generation) == generation && record.fetch(:commit_id) == commit_id
          raise ProtocolError, "AgentCore session message identity is invalid"
        end
      end

      def normalize_checkpoint(value, format: CHECKPOINT_EVENT_TYPE)
        if serialize_checkpoint(value.transform_keys(&:to_s)).bytesize > MAX_CHECKPOINT_SERIALIZED_BYTES
          raise ProtocolError, "AgentCore session checkpoint exceeds the byte limit"
        end

        data = value.transform_keys(&:to_s)
        generation = data.fetch("generation")
        generation_revision = data.fetch("generation_revision")
        commit_id = data.fetch("commit_id")
        parent_commit_id = data["parent_commit_id"]
        revision = data.fetch("revision")
        root = data.fetch("root")
        start_sequence = data.fetch("start_sequence")
        added_count = data.fetch("added_count")
        message_count = data.fetch("message_count")
        serialized_bytes = data.fetch("serialized_bytes")
        event_count = data.fetch("event_count")
        payload_count = data.fetch("payload_count")
        state = DataMap.new(data.fetch("state", {})).to_h
        metadata = DataMap.new(data.fetch("metadata", {})).to_h
        valid = valid_identifier?(generation) && valid_identifier?(commit_id) &&
          (parent_commit_id.nil? || valid_identifier?(parent_commit_id)) &&
          generation_revision.is_a?(Integer) && generation_revision.between?(1, MAX_REVISION) &&
          generation_revision <= revision &&
          revision.is_a?(Integer) && revision.between?(1, MAX_REVISION) && [true, false].include?(root) &&
          start_sequence.is_a?(Integer) && start_sequence.between?(0, MAX_SESSION_MESSAGES) &&
          added_count.is_a?(Integer) && added_count.between?(0, MAX_SESSION_MESSAGES) &&
          message_count.is_a?(Integer) && message_count.between?(0, MAX_SESSION_MESSAGES) &&
          serialized_bytes.is_a?(Integer) && serialized_bytes.between?(0, MAX_SESSION_SERIALIZED_BYTES) &&
          event_count.is_a?(Integer) && event_count.between?(0, MAX_GENERATION_EVENTS) &&
          payload_count.is_a?(Integer) && payload_count.between?(0, MAX_GENERATION_PAYLOADS) &&
          state.is_a?(Hash) && metadata.is_a?(Hash)
        raise ArgumentError unless valid

        {
          generation:,
          generation_revision:,
          commit_id:,
          parent_commit_id:,
          revision:,
          root:,
          start_sequence:,
          added_count:,
          message_count:,
          serialized_bytes:,
          event_count:,
          payload_count:,
          state:,
          metadata:
        }.freeze
      rescue JSON::GeneratorError, KeyError, NoMethodError, ArgumentError, TypeError => error
        raise ProtocolError, "AgentCore session checkpoint is invalid: #{error.class}"
      end

      def valid_identifier?(value)
        value.is_a?(String) && !value.empty? && value.length <= 256
      end

      def conversational_text(payload)
        conversational = payload.respond_to?(:conversational) ? payload.conversational : nil
        content = conversational&.respond_to?(:content) ? conversational.content : nil
        text = content&.respond_to?(:text) ? content.text : nil
        role = conversational&.respond_to?(:role) ? conversational.role : nil
        unless text.is_a?(String) && !text.empty? && text.length <= CONVERSATIONAL_TEXT_LIMIT &&
            %w[ASSISTANT USER TOOL OTHER].include?(role.to_s.upcase)
          raise ProtocolError, "AgentCore session conversational payload is invalid"
        end

        text
      end

      def next_event_timestamp(previous_timestamp)
        desired = @clock.call
        raise ProtocolError, "AgentCore session clock returned an invalid time" unless desired.is_a?(Time)

        desired = Time.at(desired.to_i)
        return desired unless previous_timestamp

        minimum = Time.at(previous_timestamp.to_i) + EVENT_TIMESTAMP_INCREMENT
        (desired > minimum) ? desired : minimum
      end

      def role_to_agent_core(role)
        case role.to_sym
        when :assistant then "ASSISTANT"
        when :tool then "TOOL"
        when :user then "USER"
        else "OTHER"
        end
      end

      def required_actor_id(actor_id)
        value = actor_id.to_s
        raise ConfigurationError, "AgentCore Memory sessions require an actor_id" if value.empty?

        value
      end
    end
  end
end
