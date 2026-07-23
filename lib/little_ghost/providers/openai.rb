# frozen_string_literal: true

require_relative "openai_compatible"

module LittleGhost
  module Providers
    class OpenAI < OpenAICompatible
      DEFAULT_BASE_URL = "https://api.openai.com/v1/"

      def initialize(base_url: DEFAULT_BASE_URL, **arguments)
        super
      end
    end
  end
end
