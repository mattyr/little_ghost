# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require_relative "../data_map"
require_relative "../session_store"

module LittleGhost
  module SessionStores
    # Filesystem preserves LittleGhost sessions across process restarts in an
    # application-controlled directory. Use it for durable local development,
    # a single-host service, or processes that share a suitable filesystem.
    #
    #   store = LittleGhost::SessionStores::Filesystem.new(
    #     root: "/var/lib/customer_support/sessions"
    #   )
    #
    # Configure the resulting store through Configuration#session_store, or
    # pass it directly when opening a Session. Calls for the same session wait
    # for one writer, including when separate Ruby processes share the root.
    #
    # **Warning:** The root contains readable session data and is not encrypted.
    # Its complete path must be application-controlled: anyone able to read it
    # can read session data, and anyone able to replace it can alter sessions.
    #
    # Session data is stored as ordinary JSON with canonical String keys. A
    # value outside that boundary raises ProtocolError without replacing the
    # previous snapshot. Shared roots require filesystem support for file
    # locking and atomic rename. From an active scheduler fiber, LittleGhost
    # performs each complete lock-and-write transaction on a joined blocking
    # worker so filesystem latency does not stop unrelated fibers. Store calls
    # do not accept cancellation or deadlines, so a lock wait continues until
    # the other process releases it.
    class Filesystem < SessionStore
      FORMAT_VERSION = 1 # :nodoc:
      LOCK_RETRY_INTERVAL = 0.01 # :nodoc:

      # Creates a store rooted at +root+ and creates the directory when needed.
      #
      # +root+ must be a private, non-symlinked directory. The application owns
      # the complete path and must not let an untrusted request choose it.
      # Raises ArgumentError when the root does not meet those requirements.
      def initialize(root:)
        super()
        @root = File.expand_path(String(root))
        raise ArgumentError, "root must not be empty" if root.to_s.empty?

        Support::BlockingOperation.call do
          FileUtils.mkdir_p(@root, mode: 0o700)
          validate_root!
        end
      end

      # Returns the stored snapshot for +id+, or +nil+ before the first write.
      #
      # +actor_id+ must match the actor that created an existing session.
      # Raises Error for an actor mismatch and ProtocolError for an invalid or
      # unsafe persisted snapshot.
      def load(id, actor_id: nil)
        with_lock(id) do
          snapshot = read_snapshot(id)
          validate_actor!(snapshot, actor_id) if snapshot
          snapshot
        end
      end

      # Atomically appends sanitized +messages+ and returns the updated snapshot.
      #
      # +expected_count+ must match the stored history length. +state+ and
      # +metadata+ must meet this store's JSON boundary. Raises ProtocolError
      # when another writer changed the session or the snapshot cannot be read
      # or written. Raises Error when +actor_id+ does not match the session.
      def append(id, messages:, state:, metadata:, expected_count:, actor_id: nil)
        messages = persistable_messages(messages)
        state = canonical_map(state)
        metadata = canonical_map(metadata)
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

      # Atomically replaces the complete persisted snapshot and returns it.
      #
      # +state+, +metadata+, and +actor_id+ follow the same requirements as
      # #append.
      def replace(id, messages:, state:, metadata:, actor_id: nil)
        messages = persistable_messages(messages)
        state = canonical_map(state)
        metadata = canonical_map(metadata)
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
        Support::BlockingOperation.call do
          path = lock_path(id)
          validate_entry!(path) if File.exist?(path) || File.symlink?(path)
          File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
            sleep(LOCK_RETRY_INTERVAL) until lock.flock(File::LOCK_EX | File::LOCK_NB)
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end

      def read_snapshot(id)
        path = snapshot_path(id)
        return unless File.exist?(path) || File.symlink?(path)

        validate_entry!(path)

        document = JSON.parse(File.binread(path))
        validate_document!(document)
        snapshot = document.fetch("snapshot")
        validate_snapshot!(snapshot)
        {
          actor_digest: document.fetch("actor_digest"),
          messages: Array(snapshot.fetch("messages")).map { |message| Message.coerce(message) }.freeze,
          state: snapshot.fetch("state"),
          metadata: snapshot.fetch("metadata")
        }.freeze
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError => error
        raise ProtocolError, "Filesystem session snapshot is invalid: #{error.class}"
      end

      def write_snapshot(id, snapshot)
        serialized_snapshot = public_snapshot(snapshot).merge(
          messages: snapshot.fetch(:messages).map(&:to_h)
        )
        document = {
          "version" => FORMAT_VERSION,
          "actor_digest" => snapshot.fetch(:actor_digest),
          "snapshot" => serialized_snapshot
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
        raise ArgumentError unless snapshot.fetch("messages").is_a?(Array)
        DataMap.new(snapshot.fetch("state"))
        DataMap.new(snapshot.fetch("metadata"))
      end

      def canonical_map(value)
        DataMap.new(value).to_h
      rescue ArgumentError => error
        raise ProtocolError, "Filesystem session data is invalid: #{error.message}"
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
