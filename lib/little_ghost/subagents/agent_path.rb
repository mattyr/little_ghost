# frozen_string_literal: true

module LittleGhost
  module Subagents
    # AgentPath gives every delegated conversation a stable place beneath its
    # parent. Paths begin at +/root+, keeping nested delegation visible in logs
    # and metadata.
    #
    # Child task names contain only lowercase letters,
    # digits, and underscores, are limited to 40 characters, and must be unique
    # among siblings when reserved by a manager.
    #
    #   AgentPath.join("/root", "review_api") # => "/root/review_api"
    class AgentPath
      ROOT = "/root" # :nodoc:
      MAX_NAME_LENGTH = 40 # :nodoc:
      MAX_PATH_LENGTH = 1024 # :nodoc:
      NAME_PATTERN = /\A[a-z0-9_]+\z/ # :nodoc:

      class << self
        # Validates an absolute agent path and returns it unchanged.
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

        # Validates both parts and returns a direct child path.
        def join(parent, name)
          validate!("#{validate!(parent)}/#{validate_name!(name)}")
        end

        # Validates and returns one model-chosen task name.
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

        # Checks whether +path+ is exactly one level beneath +parent+.
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
