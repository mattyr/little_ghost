# frozen_string_literal: true

module LittleGhost
  # Ready-to-use persistence implementations for LittleGhost conversations.
  module SessionStores
    # Memory keeps conversations available for the life of one Ruby process. It
    # is the default store and needs no application setup.
    #
    # Data disappears when the process exits. Supplying an actor ID binds the
    # session key to that actor; a later mismatch raises an error.
    class Memory < SessionStore
      # Starts with no saved conversations.
      def initialize
        super
        @records = {}
        @records_mutex = Mutex.new
      end

      # Loads the snapshot for +id+, returning +nil+ before the first checkpoint.
      # A supplied +actor_id+ claims a new ID and must match on later access.
      def load(id, actor_id: nil)
        @records_mutex.synchronize do
          key = id.to_s
          record = @records[key]
          validate_actor!(record, actor_id)
          @records[key] = {actor_id: actor_id.to_s, snapshot: nil} if !record && actor_id
          record&.fetch(:snapshot)
        end
      end

      # Appends sanitized +messages+ when +expected_count+ still matches the
      # stored conversation, then returns the updated snapshot.
      def append(id, messages:, state:, metadata:, expected_count:, actor_id: nil)
        messages = persistable_messages(messages)
        @records_mutex.synchronize do
          key = id.to_s
          record = @records[key]
          validate_actor!(record, actor_id)
          current = record&.fetch(:snapshot) || empty_snapshot
          unless current.fetch(:messages).length == expected_count
            raise ProtocolError, "Session changed while it was being updated"
          end

          @records[key] = {
            actor_id: actor_id&.to_s,
            snapshot: {
              messages: [*current.fetch(:messages), *messages].freeze,
              state:,
              metadata:
            }.freeze
          }.freeze
          @records[key].fetch(:snapshot)
        end
      end

      # Replaces the complete in-memory snapshot with sanitized +messages+.
      def replace(id, messages:, state:, metadata:, actor_id: nil)
        messages = persistable_messages(messages)
        @records_mutex.synchronize do
          key = id.to_s
          validate_actor!(@records[key], actor_id)
          @records[key] = {
            actor_id: actor_id&.to_s,
            snapshot: {messages:, state:, metadata:}.freeze
          }.freeze
          @records[key].fetch(:snapshot)
        end
      end

      private

      def empty_snapshot
        {messages: [].freeze, state: {}.freeze, metadata: {}.freeze}.freeze
      end

      def validate_actor!(record, actor_id)
        actor = actor_id&.to_s
        return unless record
        return if record[:actor_id].nil? && actor.nil?
        return if record[:actor_id] == actor

        raise Error, "Session actor does not match"
      end
    end
  end
end
