# frozen_string_literal: true

require "fiddle"

module LittleGhost
  class Sandbox
    # Performs bounded host filesystem operations through a set of virtual
    # mounts. This broker is intended for trusted tool dispatch outside an OS
    # sandbox; path traversal is anchored to mount descriptors and rejects
    # symbolic links.
    class Filesystem # :nodoc:
      PLATFORM_OPEN_FLAGS = case RUBY_PLATFORM
      when /darwin/
        {close_on_exec: 0x0100_0000}
      when /linux/
        {close_on_exec: 0x0008_0000}
      end&.freeze
      OPENAT = if PLATFORM_OPEN_FLAGS
        Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["openat"],
          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VARIADIC],
          Fiddle::TYPE_INT
        )
      end

      def initialize(
        mounts:,
        relative_root:,
        max_read_bytes: 1_000_000,
        max_write_bytes: 1_000_000,
        max_list_entries: 10_000
      )
        @mounts = Array(mounts).sort_by { |mount| -mount.target.length }.freeze
        @relative_root = Mount.send(:normalize_virtual_path, relative_root)
        @max_read_bytes = positive_integer(max_read_bytes, "read limit")
        @max_write_bytes = positive_integer(max_write_bytes, "write limit")
        @max_list_entries = positive_integer(max_list_entries, "listing limit")
        @mount_identities = @mounts.to_h do |mount|
          root = File.realpath(mount.source)
          stat = File.stat(root)
          [mount, [root.freeze, stat.dev, stat.ino].freeze]
        rescue Errno::ENOENT
          raise ToolError, "Sandbox mount source does not exist"
        end.freeze
      end

      attr_reader :mounts, :relative_root

      def allows?(operation, path)
        writable = %i[filesystem_write filesystem_replace].include?(operation.to_sym)
        mount, relative = resolve(path, allow_root: true)
        return false if writable && !mount.writable?

        path_available?(mount, relative, allow_missing: writable)
      rescue SystemCallError, ToolError
        false
      end

      def read(path, context: nil)
        context&.check!
        mount, relative = resolve(path)
        with_file(mount, relative, flags: read_flags, mode: "r") do |file|
          validate_regular_file!(file)

          content = file.read(@max_read_bytes + 1)
          raise ToolError, "File exceeds the read limit" if content.bytesize > @max_read_bytes

          content.force_encoding(Encoding::UTF_8)
          raise ToolError, "File is not valid UTF-8 text" unless content.valid_encoding?
          content
        end
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise ToolError, "File is not valid UTF-8 text"
      rescue Errno::ELOOP
        raise ToolError, "Path cannot be a symbolic link"
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ToolError, "Path does not exist"
      end

      def list(path = ".", context: nil)
        context&.check!
        normalized_path = virtual_path(path)
        children = virtual_children(normalized_path)
        unless mounted_path?(normalized_path)
          return children.join("\n") unless children.empty?
        end

        mount, relative = resolve(normalized_path, allow_root: true)
        listing = with_directory(mount, relative) do |directory|
          entries = directory_children(directory)
          raise ToolError, "Directory exceeds the listing limit" if entries.length > @max_list_entries

          entries.sort.map do |entry|
            directory_entry?(directory, entry) ? "#{entry}/" : entry
          end
        end
        (listing + children).uniq.sort.join("\n")
      rescue Errno::ELOOP
        raise ToolError, "Path cannot traverse a symbolic link"
      rescue Errno::ENOENT
        raise ToolError, "Path does not exist"
      rescue Errno::ENOTDIR
        raise ToolError, "Path is not a directory"
      end

      def write(path, content, context: nil)
        context&.check!
        mount, relative = resolve(path)
        raise ToolError, "Sandbox scope is read-only" unless mount.writable?
        raise ToolError, "Content exceeds the write limit" if content.bytesize > @max_write_bytes

        with_file(mount, relative, flags: write_flags, mode: "w", permissions: 0o644) do |file|
          validate_regular_file!(file)

          file.truncate(0)
          file.write(content)
        end
        "Wrote #{content.bytesize} bytes to #{display_path(path)}"
      rescue Errno::ELOOP
        raise ToolError, "Write target cannot be a symbolic link"
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ToolError, "Write target parent does not exist"
      end

      def replace(path, old_text, new_text, context: nil)
        context&.check!
        raise ToolError, "Text to replace cannot be empty" if old_text.empty?

        content = read(path, context:)
        occurrences = content.scan(old_text).length
        raise ToolError, "Text was not found in #{display_path(path)}" if occurrences.zero?
        raise ToolError, "Text occurs more than once in #{display_path(path)}" if occurrences > 1

        write(path, content.sub(old_text, new_text), context:)
      end

      private

      def resolve(path, allow_root: false)
        virtual = virtual_path(path)
        lexical_mount = mounts.find { |candidate| candidate.covers?(virtual) }
        raise ToolError, "Path is outside the sandbox scope" unless lexical_mount

        relative = virtual.delete_prefix(lexical_mount.target).delete_prefix("/")
        raise ToolError, "Path must identify a sandbox entry" if relative.empty? && !allow_root
        physical_path = File.join(canonical_root(lexical_mount), relative)
        protected_mounts = mounts.select do |candidate|
          (candidate.protect_aliases? || !candidate.tool_visible?) &&
            contained?(physical_path, canonical_root(candidate))
        end
        effective_mount = [*protected_mounts, lexical_mount].max_by { |candidate| canonical_root(candidate).length }
        raise ToolError, "Path is outside the sandbox scope" unless effective_mount.tool_visible?

        effective_root = canonical_root(effective_mount)
        unless contained?(physical_path, effective_root)
          raise ToolError, "Path escapes the sandbox mount"
        end

        effective_relative = physical_path.delete_prefix(effective_root).delete_prefix(File::SEPARATOR)
        [effective_mount, effective_relative]
      rescue PolicyError => error
        raise ToolError, error.message
      end

      def virtual_path(path)
        value = String(path)
        raise ToolError, "Path contains a null byte" if value.include?("\0")
        if value.start_with?(File::SEPARATOR)
          clean_virtual_path(value)
        else
          clean_virtual_path(File.join(relative_root, value))
        end
      end

      def clean_virtual_path(value)
        components = value.split(File::SEPARATOR)
        raise ToolError, "Path escapes the sandbox scope" if components.include?("..")

        Mount.send(:normalize_virtual_path, value)
      end

      def validate_mount_root!(mount)
        expected_root, expected_dev, expected_ino = @mount_identities.fetch(mount)
        current_root = File.realpath(mount.source)
        stat = File.stat(current_root)
        unless [current_root, stat.dev, stat.ino] == [expected_root, expected_dev, expected_ino]
          raise ToolError, "Sandbox mount source changed after initialization"
        end
      rescue Errno::ENOENT
        raise ToolError, "Sandbox mount source changed after initialization"
      end

      def canonical_root(mount)
        validate_mount_root!(mount)
        @mount_identities.fetch(mount).first
      end

      def with_file(mount, relative, flags:, mode:, permissions: 0)
        with_parent_directory(mount, relative) do |directory, entry|
          file = file_for_descriptor(open_at(directory.fileno, entry, flags, permissions), mode)
          yield file
        ensure
          file&.close
        end
      end

      def with_directory(mount, relative)
        directory = open_mount_root(mount)
        components(relative).each do |component|
          child = open_child_directory(directory, component)
          directory.close
          directory = child
        end
        raise ToolError, "Path is not a directory" unless directory.stat.directory?

        yield directory
      ensure
        directory&.close
      end

      def with_parent_directory(mount, relative)
        entries = components(relative)
        raise ToolError, "Path must identify a sandbox entry" if entries.empty?

        entry = entries.pop
        directory = open_mount_root(mount)
        entries.each do |component|
          child = open_child_directory(directory, component)
          directory.close
          directory = child
        end
        yield directory, entry
      ensure
        directory&.close
      end

      def open_mount_root(mount)
        root, expected_dev, expected_ino = @mount_identities.fetch(mount)
        directory = File.open(root, directory_flags)
        stat = directory.stat
        unless stat.directory? && [stat.dev, stat.ino] == [expected_dev, expected_ino]
          raise ToolError, "Sandbox mount source changed after initialization"
        end

        directory
      rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
        directory&.close
        raise ToolError, "Sandbox mount source changed after initialization"
      rescue
        directory&.close
        raise
      end

      def path_available?(mount, relative, allow_missing:)
        return with_directory(mount, relative) { true } if relative.empty?

        with_parent_directory(mount, relative) do |directory, entry|
          descriptor = open_at(directory.fileno, entry, read_flags)
          file_for_descriptor(descriptor, "r").close
          true
        rescue Errno::ENOENT
          allow_missing
        rescue Errno::EACCES
          true
        end
      end

      def open_child_directory(directory, entry)
        child = file_for_descriptor(open_at(directory.fileno, entry, directory_flags), "r")
        raise Errno::ENOTDIR, entry unless child.stat.directory?

        child
      rescue
        child&.close unless child&.closed?
        raise
      end

      def directory_children(directory)
        duplicate = directory.dup
        opened = Dir.for_fd(duplicate.fileno)
        duplicate.autoclose = false
        opened.children
      ensure
        if opened
          opened.close
        else
          duplicate&.close
        end
      end

      def directory_entry?(directory, entry)
        opened = file_for_descriptor(open_at(directory.fileno, entry, directory_flags), "r")
        opened.stat.directory?
      rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
        false
      ensure
        opened&.close
      end

      def open_at(directory, entry, flags, permissions = 0)
        unless OPENAT
          raise ToolError, "Secure sandbox filesystem traversal is unavailable on this platform"
        end

        descriptor = OPENAT.call(directory, entry, flags, Fiddle::TYPE_UINT, permissions)
        raise SystemCallError.new("openat", Fiddle.last_error) if descriptor.negative?

        descriptor
      end

      def file_for_descriptor(descriptor, mode)
        File.for_fd(descriptor, mode, autoclose: true)
      rescue
        IO.for_fd(descriptor).close
        raise
      end

      def validate_regular_file!(file)
        stat = file.stat
        raise ToolError, "Path is not a file" unless stat.file?
        raise ToolError, "Multiply-linked files are not accessible through sandbox tools" if stat.nlink > 1
      end

      def contained?(path, root) = path == root || path.start_with?("#{root}#{File::SEPARATOR}")

      def mounted_path?(path) = mounts.any? { |mount| mount.tool_visible? && mount.covers?(path) }

      def virtual_children(path)
        prefix = (path == File::SEPARATOR) ? File::SEPARATOR : "#{path}#{File::SEPARATOR}"
        mounts.filter_map do |mount|
          next unless mount.tool_visible?
          next unless mount.target.start_with?(prefix)

          child = mount.target.delete_prefix(prefix).split(File::SEPARATOR).first
          "#{child}/" if child
        end.uniq.sort
      end

      def read_flags
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        flags |= PLATFORM_OPEN_FLAGS.fetch(:close_on_exec) if PLATFORM_OPEN_FLAGS
        flags
      end

      def write_flags
        flags = File::WRONLY | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        flags |= PLATFORM_OPEN_FLAGS.fetch(:close_on_exec) if PLATFORM_OPEN_FLAGS
        flags
      end

      def directory_flags
        raise ToolError, "Secure sandbox filesystem traversal is unavailable on this platform" unless PLATFORM_OPEN_FLAGS

        read_flags
      end

      def components(relative)
        return [] if relative.empty?

        relative.split(File::SEPARATOR)
      end

      def positive_integer(value, label)
        value = Integer(value)
        raise ArgumentError, "#{label} must be positive" unless value.positive?

        value
      end

      def display_path(path) = String(path)
    end
  end
end
