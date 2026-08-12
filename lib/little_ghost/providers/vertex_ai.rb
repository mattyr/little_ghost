# frozen_string_literal: true

require_relative "gemini"

module LittleGhost
  module Providers
    # Google Vertex AI variant of the Gemini wire protocol.
    class VertexAI < Gemini
      def initialize(model:, project:, location: "global", access_token: nil, credential_resolver: nil,
        base_url: nil, **arguments)
        @project = project.to_s
        @location = location.to_s
        @credential_resolver = credential_resolver || GoogleCredentialResolver.new(access_token:)
        raise ConfigurationError, "Vertex AI project is required" if @project.empty?

        base_url ||= "https://#{@location}-aiplatform.googleapis.com/v1/"
        super(api_key: "unused", model:, base_url:, **arguments)
      end

      protected

      def endpoint
        "projects/#{URI.encode_www_form_component(@project)}/locations/#{URI.encode_www_form_component(@location)}/publishers/google/models/#{URI.encode_www_form_component(model)}:streamGenerateContent?alt=sse"
      end

      def request_headers
        super.merge("authorization" => "Bearer #{@credential_resolver.call}")
      end
    end
  end
end
