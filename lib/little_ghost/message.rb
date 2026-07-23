# frozen_string_literal: true

require "json"

module LittleGhost
  class Message
    ROLES = %i[system developer user assistant tool].freeze

    attr_reader :role, :content, :metadata

    def initialize(role:, content:, metadata: {})
      @role = role.to_sym
      raise ArgumentError, "Unsupported message role: #{role.inspect}" unless ROLES.include?(@role)

      blocks = if content.nil?
        []
      elsif content.is_a?(Array)
        content
      else
        [content]
      end
      @content = blocks.map { |block| Content.normalize(block) }.freeze
      @metadata = metadata.freeze
      freeze
    end

    def self.coerce(value)
      return value if value.is_a?(self)

      hash = value.transform_keys(&:to_sym)
      new(**hash)
    end

    def text
      content.grep(Content::Text).map(&:text).join
    end

    def without_reasoning
      remaining_content = content.reject { |block| block.is_a?(Content::Reasoning) }
      return self if remaining_content.length == content.length

      self.class.new(role:, content: remaining_content, metadata:)
    end

    def to_h
      {"role" => role.to_s, "content" => content.map(&:to_h), "metadata" => metadata}
    end

    def to_json(*arguments)
      JSON.generate(to_h, *arguments)
    end
  end
end
