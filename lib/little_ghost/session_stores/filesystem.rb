# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

module LittleGhost
  module SessionStores
    # Filesystem keeps LittleGhost sessions in JSON files beneath an application
    # controlled directory. It is useful for durable local development, a
    # single-host service, or processes that share a filesystem with reliable
    # file locks and atomic rename support.
    #
    #   store = LittleGhost::SessionStores::Filesystem.new(
    #     root: "/var/lib/customer_support/sessions"
    #   )
    #
    # Configure the resulting store through Configuration#session_store, or
    # pass it directly when opening a Session. The root is a trust boundary:
    # session data remains readable to any process that can read its files, and
    # write access is equivalent to authority over persisted session state. The
    # root and its parent path must be application-controlled and unavailable
    # for untrusted users to rename or replace.
    # This store does not encrypt session data.
    #
    # State and metadata must contain JSON-compatible values with String or
    # Symbol hash keys. A value outside that boundary raises ProtocolError
    # without replacing the previous snapshot.
    #
    # Session and actor IDs are hashed before becoming filenames. Each write
    # holds a per-session OS file lock, writes and flushes a temporary file, and
    # atomically replaces the prior snapshot. Applications sharing the root
    # must use a filesystem that supports those operations correctly.
    class Filesystem < SessionStore
      FORMAT_VERSION = 1 # :nodoc:
      SYMBOL_KEY_PREFIX = "little_ghost:symbol:" # :nodoc:
      STRING_KEY_PREFIX = "little_ghost:string:" # :nodoc:

      # Creates the private +root+ directory when needed. The application owns
      # the root selection and should not let an untrusted request choose it.
      def initialize(root:)
        super()
        @root = File.expand_path(String(root))
        raise ArgumentError, "root must not be empty" if root.to_s.empty?

        FileUtils.mkdir_p(@root, mode: 0o700)
        validate_root!
      end

      # Loads the stored snapshot, or returns +nil+ before the first write.
      # A stored session remains bound to its original actor.
      def load(id, actor_id: nil)
        with_lock(id) do
          snapshot = read_snapshot(id)
          validate_actor!(snapshot, actor_id) if snapshot
          snapshot
        end
      end

      # Appends sanitized messages when +expected_count+ matches the stored
      # history length, then returns the updated snapshot.
      def append(id, messages:, state:, metadata:, expected_count:, actor_id: nil)
        messages = persistable_messages(messages)
        with_lock(id) do
          current = read_snapshot(id)
          validate_actor!(current, actor_id) if current
          current ||= empty_snapshot(actor_id)
          unless current.fetch(:messages).length == expected_count
            raise ProtocolError, "Session changed while it was being updated"
          end

          snapshot = {
            actor_digest: current.fetch(:actor_digest),
            messages: [*current.fetch(:messages), *messages].freeze,
            state:,
            metadata:
          }.freeze
          write_snapshot(id, snapshot)
          public_snapshot(snapshot)
        end
      end

      # Replaces the complete persisted snapshot atomically.
      def replace(id, messages:, state:, metadata:, actor_id: nil)
        messages = persistable_messages(messages)
        with_lock(id) do
          current = read_snapshot(id)
          validate_actor!(current, actor_id) if current
          snapshot = {
            actor_digest: current ? current.fetch(:actor_digest) : actor_digest(actor_id),
            messages: messages.freeze,
            state:,
            metadata:
          }.freeze
          write_snapshot(id, snapshot)
          public_snapshot(snapshot)
        end
      end

      private

      def empty_snapshot(actor_id)
        {
          actor_digest: actor_digest(actor_id),
          messages: [].freeze,
          state: {}.freeze,
          metadata: {}.freeze
        }.freeze
      end

      def public_snapshot(snapshot)
        snapshot.slice(:messages, :state, :metadata)
      end

      def validate_actor!(snapshot, actor_id)
        return if snapshot.fetch(:actor_digest) == actor_digest(actor_id)

        raise Error, "Session actor does not match"
      end

      def with_lock(id)
        path = lock_path(id)
        validate_entry!(path) if File.exist?(path) || File.symlink?(path)
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end

      def read_snapshot(id)
        path = snapshot_path(id)
        return unless File.exist?(path) || File.symlink?(path)

        validate_entry!(path)

        document = JSON.parse(File.binread(path))
        validate_document!(document)
        snapshot = decode_value(document.fetch("snapshot"))
        validate_snapshot!(snapshot)
        {
          actor_digest: document.fetch("actor_digest"),
          messages: Array(snapshot.fetch(:messages)).map { |message| Message.coerce(message) }.freeze,
          state: snapshot.fetch(:state),
          metadata: snapshot.fetch(:metadata)
        }.freeze
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError => error
        raise ProtocolError, "Filesystem session snapshot is invalid: #{error.class}"
      end

      def write_snapshot(id, snapshot)
        serialized_snapshot = public_snapshot(snapshot).merge(
          messages: snapshot.fetch(:messages).map(&:to_h)
        )
        encoded_snapshot = encode_value(serialized_snapshot)
        document = {
          "version" => FORMAT_VERSION,
          "actor_digest" => snapshot.fetch(:actor_digest),
          "snapshot" => encoded_snapshot
        }
        document["digest"] = Digest::SHA256.hexdigest(JSON.generate(document))
        write_atomically(snapshot_path(id), JSON.generate(document))
      rescue JSON::GeneratorError, TypeError => error
        raise ProtocolError, "Filesystem session snapshot could not be serialized: #{error.class}"
      end

      def validate_document!(document)
        raise ArgumentError unless document.is_a?(Hash)
        raise ArgumentError unless document.fetch("version") == FORMAT_VERSION
        raise ArgumentError unless document.fetch("actor_digest").match?(/\A[0-9a-f]{64}\z/)
        digest = document.fetch("digest")
        raise ArgumentError unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)

        expected = document.except("digest")
        raise ArgumentError unless Digest::SHA256.hexdigest(JSON.generate(expected)) == digest
      end

      def validate_snapshot!(snapshot)
        raise ArgumentError unless snapshot.is_a?(Hash)
        raise ArgumentError unless snapshot.fetch(:messages).is_a?(Array)
        raise ArgumentError unless snapshot.fetch(:state).is_a?(Hash)
        raise ArgumentError unless snapshot.fetch(:metadata).is_a?(Hash)
      end

      def encode_value(value)
        case value
        when Hash
          value.to_h do |key, child|
            prefix = key.is_a?(Symbol) ? SYMBOL_KEY_PREFIX : STRING_KEY_PREFIX
            raise TypeError unless key.is_a?(String) || key.is_a?(Symbol)

            ["#{prefix}#{key}", encode_value(child)]
          end
        when Array
          value.map { |child| encode_value(child) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          raise TypeError
        end
      end

      def decode_value(value)
        case value
        when Hash
          value.to_h do |key, child|
            raise ArgumentError unless key.start_with?(SYMBOL_KEY_PREFIX, STRING_KEY_PREFIX)

            decoded = if key.start_with?(SYMBOL_KEY_PREFIX)
              key.delete_prefix(SYMBOL_KEY_PREFIX).to_sym
            else
              key.delete_prefix(STRING_KEY_PREFIX)
            end
            [decoded, decode_value(child)]
          end
        when Array
          value.map { |child| decode_value(child) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          raise ArgumentError
        end
      end

      def write_atomically(path, content)
        validate_entry!(path) if File.exist?(path) || File.symlink?(path)
        temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp"
        File.open(temporary, "wb", 0o600) do |file|
          file.write(content)
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
        sync_root
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end

      def sync_root
        File.open(@root, File::RDONLY) { |directory| directory.fsync }
      rescue SystemCallError
        nil
      end

      def validate_root!
        stat = File.lstat(@root)
        unless stat.directory? && !stat.symlink? && private_mode?(stat)
          raise ArgumentError, "root must be a private, non-symlinked directory"
        end
      end

      def validate_entry!(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && private_mode?(stat)
          raise ProtocolError, "Filesystem session entry is unsafe"
        end
      rescue Errno::ENOENT
        nil
      end

      def private_mode?(stat)
        (stat.mode & 0o077).zero?
      end

      def snapshot_path(id)
        File.join(@root, "#{session_digest(id)}.json")
      end

      def lock_path(id)
        File.join(@root, "#{session_digest(id)}.lock")
      end

      def session_digest(id)
        Digest::SHA256.hexdigest("little_ghost/filesystem_session/v1\0#{String(id)}")
      end

      def actor_digest(actor_id)
        Digest::SHA256.hexdigest(JSON.generate([actor_id.nil?, actor_id&.to_s]))
      end
    end
  end
end
