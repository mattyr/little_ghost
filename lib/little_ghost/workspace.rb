# frozen_string_literal: true

module LittleGhost
  class Workspace
    def initialize(root:, writable: false, max_read_bytes: 1_000_000, max_write_bytes: 1_000_000, max_list_entries: 10_000)
      expanded_root = File.expand_path(root)
      @root = File.exist?(expanded_root) ? File.realpath(expanded_root) : expanded_root
      @root_identity = if File.exist?(@root)
        File.stat(@root).then { |stat| [stat.dev, stat.ino] }.freeze
      end
      @writable = writable
      @max_read_bytes = Integer(max_read_bytes)
      @max_write_bytes = Integer(max_write_bytes)
      @max_list_entries = Integer(max_list_entries)
      unless [@max_read_bytes, @max_write_bytes, @max_list_entries].all?(&:positive?)
        raise ArgumentError, "workspace limits must be positive"
      end
    end

    attr_reader :root

    def writable? = @writable

    def close
      nil
    end

    def read(path)
      File.open(existing_path(path), read_flags) do |file|
        raise ToolError, "Path is not a file" unless file.stat.file?

        content = file.read(@max_read_bytes + 1)
        raise ToolError, "File exceeds the read limit" if content.bytesize > @max_read_bytes

        content.force_encoding(Encoding::UTF_8)
        raise ToolError, "File is not valid UTF-8 text" unless content.valid_encoding?
        content
      end
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      raise ToolError, "File is not valid UTF-8 text"
    end

    def write(path, content)
      raise ToolError, "Workspace is read-only" unless @writable
      raise ToolError, "Content exceeds the write limit" if content.bytesize > @max_write_bytes

      flags = File::WRONLY | File::CREAT | File::TRUNC
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      flags |= File::NONBLOCK if defined?(File::NONBLOCK)
      File.open(writable_path(path), flags, 0o644) do |file|
        raise ToolError, "Path is not a file" unless file.stat.file?

        file.write(content)
      end
      "Wrote #{content.bytesize} bytes to #{display_path(path)}"
    rescue Errno::ELOOP
      raise ToolError, "Write target cannot be a symbolic link"
    end

    def replace(path, old_text, new_text)
      raise ToolError, "Text to replace cannot be empty" if old_text.empty?

      content = read(path)
      occurrences = content.scan(old_text).length
      raise ToolError, "Text was not found in #{display_path(path)}" if occurrences.zero?
      raise ToolError, "Text occurs more than once in #{display_path(path)}" if occurrences > 1

      write(path, content.sub(old_text, new_text))
    end

    def list(path = ".")
      directory = existing_path(path, allow_root: true)
      raise ToolError, "Path is not a directory" unless File.directory?(directory)

      entries = Dir.children(directory)
      raise ToolError, "Directory exceeds the listing limit" if entries.length > @max_list_entries

      entries.sort.map do |entry|
        File.lstat(File.join(directory, entry)).directory? ? "#{entry}/" : entry
      end.join("\n")
    end

    private

    def existing_path(path, allow_root: false)
      candidate = expanded_path(path, allow_root:)
      validate_root!
      resolved = File.realpath(candidate)
      ensure_within_root!(resolved)
      resolved
    rescue Errno::ENOENT
      raise ToolError, "Path does not exist"
    end

    def writable_path(path)
      candidate = expanded_path(path)
      validate_root!
      raise ToolError, "Write target cannot be a symbolic link" if File.symlink?(candidate)

      if File.exist?(candidate)
        resolved = File.realpath(candidate)
        ensure_within_root!(resolved)
        resolved
      else
        parent = File.realpath(File.dirname(candidate))
        ensure_within_root!(parent)
        File.join(parent, File.basename(candidate))
      end
    rescue Errno::ENOENT
      raise ToolError, "Path does not exist"
    end

    def expanded_path(path, allow_root: false)
      components = path_components(path)
      raise ToolError, "Path must identify a workspace entry" if components.empty? && !allow_root

      File.join(@root, *components)
    end

    def ensure_within_root!(path)
      root_prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
      return path if path == @root || path.start_with?(root_prefix)

      raise ToolError, "Path escapes the configured workspace"
    end

    def validate_root!
      identity = File.stat(File.realpath(@root)).then { |stat| [stat.dev, stat.ino] }
      raise ToolError, "Workspace root changed after initialization" unless identity == @root_identity
    rescue Errno::ENOENT
      raise ToolError, "Workspace root changed after initialization"
    end

    def read_flags
      flags = File::RDONLY
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      flags |= File::NONBLOCK if defined?(File::NONBLOCK)
      flags
    end

    def path_components(path)
      value = String(path)
      raise ToolError, "Path contains a null byte" if value.include?("\0")
      raise ToolError, "Path must be relative to the workspace" if value.start_with?(File::SEPARATOR)

      value.split(File::SEPARATOR).reject { |component| component.empty? || component == "." }.tap do |components|
        raise ToolError, "Path escapes the configured workspace" if components.include?("..")
      end
    end

    def display_path(path)
      path_components(path).join(File::SEPARATOR)
    end
  end
end
