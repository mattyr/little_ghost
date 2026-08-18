# frozen_string_literal: true

require_relative "gemini"
require_relative "vertex_ai/credential_resolver"

module LittleGhost
  module Providers
    # Connects a Model to Gemini models hosted by Google Vertex AI.
    #
    # It sends the same request content as the Gemini adapter to the configured
    # Google Cloud project and location. A trusted credential resolver supplies
    # each access token. Cancellation, deadlines, normalized streaming events,
    # and ProviderError behavior match Providers::Gemini.
    class VertexAI < Gemini
      # Creates a Vertex AI client for a Google Cloud +project+ and +location+.
      def initialize(model:, project:, location: "global", access_token: nil, credential_resolver: nil,
        base_url: nil, **arguments)
        @project = project.to_s
        @location = location.to_s
        @credential_resolver = credential_resolver || CredentialResolver.new(access_token:)
        raise ConfigurationError, "Vertex AI project is required" if @project.empty?

        base_url ||= "https://#{@location}-aiplatform.googleapis.com/v1/"
        super(api_key: "unused", model:, base_url:, **arguments)
      end

      protected

      def endpoint
        "projects/#{URI.encode_www_form_component(@project)}/locations/#{URI.encode_www_form_component(@location)}/publishers/google/models/#{URI.encode_www_form_component(model)}:streamGenerateContent?alt=sse"
      end

      def request_headers(request)
        super.merge(
          "authorization" => "Bearer #{@credential_resolver.call(
            cancellation_token: request.cancellation_token,
            deadline: request.deadline
          )}"
        )
      end
    end
  end
end
