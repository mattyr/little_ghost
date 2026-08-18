# frozen_string_literal: true

require "pathname"

module LittleGhost
  module Skills
    module ResourceRoot # :nodoc:
      module_function

      def normalize(value)
        return unless value

        path = value.to_s
        return normalize_workspace_reference(path) if path.start_with?("workspace://")

        unless valid_absolute_path?(path)
          raise ArgumentError, "resource_root must be an absolute path or workspace:// reference"
        end

        File.expand_path(path).freeze
      end

      def normalize_workspace_reference(path)
        logical = path.delete_prefix("workspace://")
        components = logical.split("/", -1)
        name = components.shift
        invalid = name.nil? || !name.match?(/\A[a-zA-Z0-9_-]+\z/) ||
          components.any? { |component| component.empty? || component == "." || component == ".." }
        if invalid || path.include?("\0") || path.include?("\\")
          raise ArgumentError, "resource_root must be an absolute path or workspace:// reference"
        end

        path.dup.freeze
      end

      def valid_absolute_path?(path)
        !path.include?("\0") && Pathname.new(path).absolute? &&
          !path.split(File::SEPARATOR).include?("..")
      end
    end
  end
end
