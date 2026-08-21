# frozen_string_literal: true

require "digest"
require "fiddle"
require "json"
require "securerandom"

module LittleGhost
  module Artifacts
    # Writes immutable artifacts beneath one named Workspace path. The store
    # applies per-artifact, total-byte, and count limits before exposing a file.
    # It does not remove files; the Workspace provider owns their lifetime.
    class WorkspaceStore # :nodoc:
      ContextControl = Data.define(:cancellation_tokens, :deadlines) do # :nodoc:
        def check!
          cancelled = cancellation_tokens.any? do |token|
            Support::CancellationToken.instance_method(:cancelled?).bind_call(token)
          end
          raise CancelledError, "The run was cancelled" if cancelled
          if deadlines.any? { |deadline| Time.now.to_f >= deadline }
            raise DeadlineExceededError, "The run deadline was reached"
          end
        end
      end

      PLATFORM_OPEN_FLAGS = case RUBY_PLATFORM
      when /darwin/
        {close_on_exec: 0x0100_0000}
      when /linux/
        {close_on_exec: 0x0008_0000}
      end&.freeze # :nodoc:
      OPENAT = if PLATFORM_OPEN_FLAGS # :nodoc:
        Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["openat"],
          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VARIADIC],
          Fiddle::TYPE_INT
        )
      end
      UNLINKAT = if PLATFORM_OPEN_FLAGS # :nodoc:
        Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["unlinkat"],
          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )
      end

      # Default maximum size of one artifact: 32 MiB.
      DEFAULT_MAX_ARTIFACT_BYTES = 32 * 1024 * 1024
      # Default cumulative store budget: 64 MiB.
      DEFAULT_MAX_TOTAL_BYTES = 64 * 1024 * 1024
      # Default maximum number of unique artifacts.
      DEFAULT_MAX_ARTIFACTS = 100

      # Uses the already-open +workspace+ and a configured named +path+.
      def initialize(
        workspace:,
        path: :artifacts,
        max_artifact_bytes: DEFAULT_MAX_ARTIFACT_BYTES,
        max_total_bytes: DEFAULT_MAX_TOTAL_BYTES,
        max_artifacts: DEFAULT_MAX_ARTIFACTS
      )
        raise ToolError, "Artifact workspace path is unavailable" unless workspace

        @workspace = workspace
        @path = path.to_sym
        @max_artifact_bytes = positive_integer(max_artifact_bytes, :max_artifact_bytes)
        @max_total_bytes = positive_integer(max_total_bytes, :max_total_bytes)
        @max_artifacts = positive_integer(max_artifacts, :max_artifacts)
        @mutex = Mutex.new
        @artifacts = {}
        @total_bytes = 0
        @namespace = SecureRandom.hex(8).freeze
        @root, @root_identity = Support::BlockingOperation.call { validate_root! }
      end

      # Materializes +data+ once for an identical name, media type, and byte
      # sequence. Concurrent calls share one descriptor and consume one budget.
      def write(data:, name: nil, media_type: nil, metadata: {}, context: nil)
        write_batch([{data:, name:, media_type:, metadata:}], context:).fetch(0)
      end

      # Atomically materializes an Array of write keyword Hashes. If any new
      # artifact fails, every file and budget reservation created by this call
      # is rolled back; previously cached artifacts remain unchanged.
      def write_batch(entries, context: nil)
        raise ArgumentError, "artifact batch must be an array" unless entries.is_a?(Array)

        context&.check!
        control = context_control(context)
        Support::BlockingOperation.call do
          prepared = entries.map { |entry| prepare_entry(entry) }
          @mutex.synchronize do
            control&.check!
            created = []
            begin
              prepared.map do |entry|
                control&.check!
                digest = entry.fetch(:digest)
                next @artifacts.fetch(digest) if @artifacts.key?(digest)

                reserve!(entry.fetch(:data).bytesize)
                record = entry.merge(materialized: false)
                created << record
                artifact = materialize(**entry, control:)
                @artifacts[digest] = artifact
                record[:materialized] = true
                artifact
              end.freeze
            rescue => error
              rollback_batch(created, error:)
              raise
            end
          end
        end
      end

      # Number of bytes reserved by unique artifacts in this store.
      def total_bytes = @mutex.synchronize { @total_bytes }

      # Number of unique artifacts in this store.
      def size = @mutex.synchronize { @artifacts.length }

      private

      def prepare_entry(entry)
        raise ArgumentError, "artifact batch entries must be hashes" unless entry.is_a?(Hash)

        data = String(entry.fetch(:data)).b
        if data.bytesize > @max_artifact_bytes
          raise ToolError, "Artifact exceeds the #{@max_artifact_bytes}-byte limit"
        end
        media_type = entry[:media_type]
        name = normalized_name(entry[:name], media_type:)
        metadata = DataMap.new(entry.fetch(:metadata, {}))
        digest = Digest::SHA256.hexdigest(
          [name, media_type, JSON.generate(metadata), data].join("\0")
        )
        {
          data:,
          digest:,
          file_name: "#{@namespace}-#{digest}-#{name}",
          name:,
          media_type:,
          metadata:
        }
      end

      def context_control(context)
        values = if context.instance_of?(RunContext)
          {
            cancellation_tokens: [context.cancellation_token],
            deadlines: [context.deadline]
          }
        elsif context&.respond_to?(:artifact_control_values)
          context.artifact_control_values
        else
          return
        end
        tokens = Array(values.fetch(:cancellation_tokens)).select do |token|
          token.instance_of?(Support::CancellationToken)
        end.freeze
        deadlines = Array(values.fetch(:deadlines)).compact.filter_map do |deadline|
          deadline.to_f if deadline.instance_of?(Time)
        end.freeze
        ContextControl.new(cancellation_tokens: tokens, deadlines: deadlines)
      rescue KeyError, NoMethodError, TypeError
        nil
      end

      def reserve!(bytes)
        raise ToolError, "Artifact count exceeds the #{@max_artifacts}-item limit" if @artifacts.length >= @max_artifacts
        if @total_bytes + bytes > @max_total_bytes
          raise ToolError, "Artifacts exceed the #{@max_total_bytes}-byte total limit"
        end

        @total_bytes += bytes
      end

      def materialize(data:, digest:, file_name:, name:, media_type:, metadata:, control:)
        directory = open_root
        path = File.join(@root, file_name)
        created = false
        descriptor = open_at(directory.fileno, file_name, write_flags, 0o600)
        created = true
        file = file_for_descriptor(descriptor, "w")
        begin
          file.binmode
          file.write(data)
          file.flush
          file.chmod(0o600)
          validate_regular_file!(file)
        ensure
          file.close
        end
        control&.check!
        @workspace.validate!
        Artifact.materialized(
          reference: @workspace.reference(path),
          name:,
          media_type:,
          bytes: data.bytesize,
          metadata:
        )
      rescue Errno::EEXIST
        raise ToolError, "Artifact destination already exists"
      rescue Errno::ELOOP
        raise ToolError, "Artifact destination is unsafe"
      rescue => error
        cleanup_created_file(directory, file_name, error:) if created
        raise
      ensure
        directory&.close
      end

      def rollback_batch(records, error:)
        cleanup_errors = []
        records.reverse_each do |record|
          unless record.fetch(:materialized)
            @total_bytes -= record.fetch(:data).bytesize
            next
          end

          begin
            unlink_entry(record.fetch(:file_name))
            @artifacts.delete(record.fetch(:digest))
            @total_bytes -= record.fetch(:data).bytesize
          rescue => cleanup_error
            cleanup_errors << cleanup_error
          end
        end
        return if cleanup_errors.empty?

        raise CleanupError,
          "Artifact batch rollback failed after #{error.class} (#{cleanup_errors.first.class})"
      end

      def unlink_entry(entry)
        directory = open_root
        unlink_at(directory.fileno, entry)
      ensure
        directory&.close
      end

      def validate_root!
        unless OPENAT && UNLINKAT
          raise ToolError, "Secure artifact storage is unavailable on this platform"
        end

        @workspace.validate!
        root = @workspace.path(@path)
        stat = File.lstat(root)
        real = File.realpath(root)
        workspace_real = File.realpath(@workspace.root)
        location_safe = !beneath?(root, @workspace.root) || beneath?(real, workspace_real)
        unless stat.directory? && !stat.symlink? && location_safe
          raise ToolError, "Artifact workspace path is unsafe"
        end

        directory = File.open(root, directory_flags)
        descriptor_stat = directory.stat
        unless descriptor_stat.directory?
          raise ToolError, "Artifact workspace path is unsafe"
        end
        @workspace.validate!
        [root.freeze, [descriptor_stat.dev, descriptor_stat.ino].freeze].freeze
      rescue KeyError, Errno::ENOENT, Errno::ENOTDIR
        raise ToolError, "Artifact workspace path is unavailable"
      rescue SystemCallError
        raise ToolError, "Artifact workspace path is unavailable"
      ensure
        directory&.close
      end

      def open_root
        @workspace.validate!
        directory = File.open(@root, directory_flags)
        stat = directory.stat
        unless stat.directory? && [stat.dev, stat.ino] == @root_identity
          raise ToolError, "Artifact workspace path changed after initialization"
        end
        @workspace.validate!
        directory
      rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
        directory&.close
        raise ToolError, "Artifact workspace path changed after initialization"
      rescue
        directory&.close
        raise
      end

      def open_at(directory, entry, flags, permissions)
        descriptor = OPENAT.call(directory, entry, flags, Fiddle::TYPE_UINT, permissions)
        raise SystemCallError.new("openat", Fiddle.last_error) if descriptor.negative?

        descriptor
      end

      def unlink_at(directory, entry)
        result = UNLINKAT.call(directory, entry, 0)
        raise SystemCallError.new("unlinkat", Fiddle.last_error) if result.negative?
      end

      def file_for_descriptor(descriptor, mode)
        File.for_fd(descriptor, mode, autoclose: true)
      rescue
        IO.for_fd(descriptor).close
        raise
      end

      def validate_regular_file!(file)
        stat = file.stat
        unless stat.file? && stat.nlink == 1 && (stat.mode & 0o777) == 0o600
          raise ToolError, "Artifact destination is unsafe"
        end
      end

      def cleanup_created_file(directory, entry, error:)
        unlink_at(directory.fileno, entry)
      rescue => cleanup_error
        raise CleanupError,
          "Artifact cleanup failed after #{error.class} (#{cleanup_error.class})"
      end

      def write_flags
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        flags |= PLATFORM_OPEN_FLAGS.fetch(:close_on_exec)
        flags
      end

      def directory_flags
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        flags |= PLATFORM_OPEN_FLAGS.fetch(:close_on_exec)
        flags
      end

      def normalized_name(name, media_type:)
        value = name.to_s
        value = default_name(media_type) if value.empty?
        value = File.basename(value).scrub.gsub(/[^A-Za-z0-9._-]/, "_")
        value = "artifact" if value.empty? || value == "." || value == ".."
        value.byteslice(0, 120)
      end

      def default_name(media_type)
        extension = {
          "application/json" => ".json",
          "text/plain" => ".txt",
          "text/markdown" => ".md",
          "image/png" => ".png",
          "image/jpeg" => ".jpg",
          "application/pdf" => ".pdf"
        }[media_type.to_s]
        "artifact#{extension}"
      end

      def beneath?(candidate, base)
        candidate == base || candidate.start_with?(base.end_with?(File::SEPARATOR) ? base : "#{base}#{File::SEPARATOR}")
      end

      def positive_integer(value, name)
        integer = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless integer.positive?

        integer
      end
    end
  end
end
