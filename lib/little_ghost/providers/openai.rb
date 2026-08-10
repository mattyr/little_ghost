# frozen_string_literal: true

require_relative "openai_compatible"

module LittleGhost
  module Providers
    # OpenAI connects LittleGhost agents to OpenAI models with streaming, tools,
    # and structured results. It uses the Responses API by default.
    #
    #   provider = LittleGhost::Providers::OpenAI.new(
    #     api_key: ENV.fetch("OPENAI_API_KEY"),
    #     model: ENV.fetch("OPENAI_MODEL")
    #   )
    #
    # Supply <tt>api: :chat_completions</tt> only when a model or integration requires
    # the Chat Completions wire API.
    class OpenAI < OpenAICompatible
      # The OpenAI API endpoint used when +base_url+ is omitted.
      DEFAULT_BASE_URL = "https://api.openai.com/v1/"

      # Uses the official OpenAI API base URL by default.
      def initialize(base_url: DEFAULT_BASE_URL, **arguments)
        super
      end
    end
  end
end
