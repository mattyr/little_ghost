# frozen_string_literal: true

module LittleGhost
  module Subagents
    class AgentPath
      ROOT = "/root"
      MAX_NAME_LENGTH = 40
      MAX_PATH_LENGTH = 1024
      NAME_PATTERN = /\A[a-z0-9_]+\z/

      class << self
        def validate!(path)
          value = String(path)
          raise ArgumentError, "agent path must start with /root" unless value == ROOT || value.start_with?("#{ROOT}/")
          raise ArgumentError, "agent path must not end with /" if value.end_with?("/")
          raise ArgumentError, "agent path is too long" if value.length > MAX_PATH_LENGTH

          segments = value.split("/").drop(2)
          raise ArgumentError, "agent path must not contain empty segments" if segments.any?(&:empty?)

          segments.each { |segment| validate_name!(segment) }
          value
        end

        def join(parent, name)
          validate!("#{validate!(parent)}/#{validate_name!(name)}")
        end

        def validate_name!(name)
          value = String(name)
          if value.length > MAX_NAME_LENGTH
            raise ArgumentError, "task_name must be at most #{MAX_NAME_LENGTH} characters"
          end
          if value == "root" || !value.match?(NAME_PATTERN)
            raise ArgumentError, "task_name must use lowercase letters, digits, and underscores"
          end

          value
        end

        def immediate_child?(path, parent)
          value = validate!(path)
          ancestor = validate!(parent)
          value.start_with?("#{ancestor}/") &&
            !value.delete_prefix("#{ancestor}/").include?("/")
        end
      end
    end
  end
end
