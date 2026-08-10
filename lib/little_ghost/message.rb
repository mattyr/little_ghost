# frozen_string_literal: true

require "json"

module LittleGhost
  # A Message carries one participant's contribution to an agent conversation.
  # Its content can combine text, attachments, tool activity, and model reasoning.
  #
  # Content is normalized into {Content}[rdoc-ref:LittleGhost::Content] blocks
  # held in a frozen Array. Strings become Content::Text blocks, and hashes use
  # the serialized content shape accepted by Content.normalize. Nested values
  # supplied by the caller are retained rather than defensively copied.
  #
  #   message = LittleGhost::Message.new(role: :user, content: "Hello")
  #   message.text # => "Hello"
  class Message
    # Participant roles accepted by Message.new.
    ROLES = %i[system developer user assistant tool].freeze

    # Participant role, normalized Content blocks, and application metadata.
    attr_reader :role, :content, :metadata

    # Creates a frozen message with a supported +role+, normalized +content+, and
    # application-defined +metadata+. The content Array and metadata Hash are
    # frozen, but nested caller-owned values are retained.
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

    # Keeps +value+ when it is already a message, or creates a message from a
    # hash with string or symbol keys.
    def self.coerce(value)
      return value if value.is_a?(self)

      hash = value.transform_keys(&:to_sym)
      new(**hash)
    end

    # Joins the visible text blocks without including reasoning or tool content.
    def text
      content.grep(Content::Text).map(&:text).join
    end

    # Removes Content::Reasoning blocks, or keeps +self+ when none are
    # present.
    def without_reasoning
      remaining_content = content.reject { |block| block.is_a?(Content::Reasoning) }
      return self if remaining_content.length == content.length

      self.class.new(role:, content: remaining_content, metadata:)
    end

    # Produces the JSON-safe message representation.
    def to_h
      {"role" => role.to_s, "content" => content.map(&:to_h), "metadata" => metadata}
    end

    # Encodes #to_h as JSON, forwarding generator +arguments+.
    def to_json(*arguments)
      JSON.generate(to_h, *arguments)
    end
  end
end
