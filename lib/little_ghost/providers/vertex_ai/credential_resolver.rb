# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "uri"

module LittleGhost
  module Providers
    class VertexAI < Gemini
      # Resolves Vertex access tokens from explicit values, service-account ADC,
      # or the Google metadata server.
      class CredentialResolver
        TOKEN_URI = URI("https://oauth2.googleapis.com/token") # :nodoc:
        SCOPE = "https://www.googleapis.com/auth/cloud-platform" # :nodoc:

        # Uses an explicit token or Google application credentials in +environment+.
        def initialize(environment: ENV, access_token: nil, clock: -> { Time.now.to_i })
          @environment = environment
          @access_token = access_token
          @clock = clock
          @mutex = Mutex.new
        end

        # Returns a current access token, refreshing cached credentials as needed.
        def call(cancellation_token: nil, deadline: nil)
          return @access_token unless @access_token.to_s.empty?

          @mutex.synchronize do
            return @cached_token if @cached_token && @expires_at && @expires_at > @clock.call + 60

            file = @environment["GOOGLE_APPLICATION_CREDENTIALS"]
            token, expires_in = if file
              service_account_token(file, cancellation_token:, deadline:)
            else
              metadata_token(cancellation_token:, deadline:)
            end
            @cached_token = token
            @expires_at = @clock.call + Integer(expires_in || 3600)
            token
          end
        end

        private

        def service_account_token(path, cancellation_token:, deadline:)
          document = JSON.parse(File.read(path))
          raise CredentialError, "Google application credentials must be a service_account" unless document["type"] == "service_account"

          now = @clock.call
          header = urlsafe(JSON.generate(alg: "RS256", typ: "JWT"))
          claim = urlsafe(JSON.generate(iss: document.fetch("client_email"), scope: SCOPE,
            aud: document["token_uri"] || TOKEN_URI.to_s, iat: now, exp: now + 3600))
          signature = OpenSSL::PKey::RSA.new(document.fetch("private_key")).sign(OpenSSL::Digest.new("SHA256"), "#{header}.#{claim}")
          assertion = "#{header}.#{claim}.#{urlsafe(signature)}"
          response = http_client.request(uri: URI(document["token_uri"] || TOKEN_URI.to_s), method: :post,
            headers: {"content-type" => "application/x-www-form-urlencoded"},
            body: URI.encode_www_form(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion:),
            cancellation_token:, deadline:)
          token_json(response)
        rescue Errno::ENOENT, JSON::ParserError, KeyError, OpenSSL::PKey::PKeyError => error
          raise CredentialError, "Google service-account credentials are invalid: #{error.message}"
        end

        def metadata_token(cancellation_token:, deadline:)
          response = http_client.request(
            uri: URI("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"),
            method: :get,
            headers: {"Metadata-Flavor" => "Google"}, body: nil, cancellation_token:, deadline:,
            allow_insecure_http: true
          )
          token_json(response)
        rescue HTTPError
          raise CredentialError, "No Vertex AI access token, service-account credentials, or metadata credentials were found"
        end

        def token_json(body)
          value = JSON.parse(body)
          [value.fetch("access_token"), value["expires_in"]]
        rescue JSON::ParserError, KeyError => error
          raise CredentialError, "Google token endpoint returned an invalid response: #{error.message}"
        end

        def urlsafe(value) = Base64.urlsafe_encode64(value, padding: false)

        def http_client = Support::HTTPClient.new(open_timeout: 2, read_timeout: 5, max_response_bytes: 1024 * 1024)
      end
    end
  end
end
