# frozen_string_literal: true

require "pathname"

module LittleGhost
  class Sandbox
    # Maps one trusted host directory into the sandbox's virtual filesystem.
    # Process and direct-tool visibility are separate: +tools: false+ keeps the
    # mount available to child processes while denying it to the filesystem
    # broker. +protect_aliases+ preserves restrictive access when the same host
    # files are reachable through a broader mount.
    class Mount
      ACCESS_MODES = %i[read_only read_write].freeze # :nodoc:

      # Returns +value+ unchanged or builds a mount from a Hash.
      def self.coerce(value, root: nil)
        return value if value.is_a?(self)
        raise PolicyError, "mount must be a Hash or Sandbox::Mount" unless value.is_a?(Hash)

        new(**value.transform_keys(&:to_sym), root:)
      end

      # Maps +source+ at the absolute virtual +target+ with the selected access.
      # +source+ is trusted host configuration, not model input.
      def initialize(source:, target:, access: :read_only, protect_aliases: false, tools: true, root: nil)
        source = File.expand_path(String(source), root)
        target = normalize_target(target)
        access = access.to_sym
        raise PolicyError, "mount access must be :read_only or :read_write" unless ACCESS_MODES.include?(access)

        @source = source.freeze
        @target = target.freeze
        @access = access
        @protect_aliases = !!protect_aliases
        @tools = !!tools
        freeze
      end

      # Absolute host directory exposed by this mount.
      attr_reader :source
      # Absolute path presented inside the sandbox.
      attr_reader :target
      # Either +:read_only+ or +:read_write+.
      attr_reader :access
      # Indicates whether the mount's access applies through physical aliases.
      attr_reader :protect_aliases
      # Indicates whether direct filesystem tools may traverse this mount.
      attr_reader :tools

      # Indicates that the mount does not permit writes.
      def read_only? = access == :read_only
      # Indicates that the mount permits writes.
      def writable? = access == :read_write
      # Indicates that physical aliases retain this mount's access.
      def protect_aliases? = protect_aliases
      # Indicates that direct filesystem tools may traverse this mount.
      def tool_visible? = tools

      # Indicates whether +path+ is this mount target or one of its descendants.
      def covers?(path)
        path = self.class.send(:normalize_virtual_path, path)
        path == target || path.start_with?("#{target}/")
      end

      # Returns a copy narrowed to +target+ and +access+. Widening raises
      # CapabilityError.
      def narrow(target: self.target, access: self.access)
        target = self.class.send(:normalize_virtual_path, target)
        raise CapabilityError, "sandbox scope cannot expose a path outside its parent mount" unless covers?(target)
        if read_only? && access.to_sym == :read_write
          raise CapabilityError, "sandbox scope cannot make a read-only mount writable"
        end

        relative = target.delete_prefix(self.target).delete_prefix("/")
        parent_root = File.realpath(source)
        child_root = relative.empty? ? parent_root : File.realpath(File.join(parent_root, relative))
        unless child_root == parent_root || child_root.start_with?("#{parent_root}#{File::SEPARATOR}")
          raise CapabilityError, "sandbox scope mount source escapes its parent"
        end
        self.class.new(
          source: child_root,
          target:,
          access:,
          protect_aliases: protect_aliases?,
          tools: tool_visible?
        )
      rescue Errno::ENOENT, Errno::EACCES
        raise CapabilityError, "sandbox scope mount source is unavailable"
      end

      # Mounts compare by their normalized mapping and access semantics.
      def ==(other)
        other.is_a?(self.class) &&
          [comparison_source, target, access, protect_aliases?, tool_visible?] ==
            [other.send(:comparison_source), other.target, other.access, other.protect_aliases?, other.tool_visible?]
      end

      alias_method :eql?, :==

      # Hashes the normalized mapping and access semantics.
      def hash = [comparison_source, target, access, protect_aliases?, tool_visible?].hash

      def self.normalize_virtual_path(path)
        value = String(path)
        raise PolicyError, "mount target contains a null byte" if value.include?("\0")
        raise PolicyError, "mount target must be absolute" unless value.start_with?(File::SEPARATOR)
        raise PolicyError, "mount target cannot contain traversal" if value.split(File::SEPARATOR).include?("..")

        Pathname.new(value).cleanpath.to_s
      end

      class << self
        private :normalize_virtual_path
      end

      private

      def comparison_source
        File.realpath(source)
      rescue Errno::ENOENT, Errno::EACCES
        source
      end

      def normalize_target(path)
        self.class.send(:normalize_virtual_path, path)
      end
    end
  end
end
