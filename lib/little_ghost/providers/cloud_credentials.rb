# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module LittleGhost
  module Providers
    AwsCredentials = Data.define(:access_key_id, :secret_access_key, :session_token, :expiration) do # :nodoc:
      def initialize(access_key_id:, secret_access_key:, session_token: nil, expiration: nil)
        raise CredentialError, "AWS access key ID and secret access key are required" if access_key_id.to_s.empty? || secret_access_key.to_s.empty?

        super(access_key_id: access_key_id.to_s, secret_access_key: secret_access_key.to_s,
              session_token: session_token&.to_s, expiration: expiration && Time.parse(expiration.to_s))
      end
    end

    # Resolves common AWS credentials without depending on an AWS SDK.
    class AwsCredentialResolver
      def initialize(environment: ENV, profile: nil, credentials_file: nil, http_get: nil)
        @environment = environment
        @profile = profile || environment["AWS_PROFILE"] || "default"
        @credentials_file = credentials_file || environment["AWS_SHARED_CREDENTIALS_FILE"] || File.expand_path("~/.aws/credentials")
        @http_get = http_get || method(:http_get)
      end

      def call
        from_environment || from_profile || from_container || from_instance_metadata ||
          raise(CredentialError, "No AWS credentials were found in the environment, selected shared profile, container credentials, or IMDSv2")
      end

      def region
        @environment["AWS_REGION"] || @environment["AWS_DEFAULT_REGION"] || profile_values(config_file)["region"]
      end

      private

      def from_environment
        key = @environment["AWS_ACCESS_KEY_ID"]
        secret = @environment["AWS_SECRET_ACCESS_KEY"]
        return unless key && secret

        AwsCredentials.new(access_key_id: key, secret_access_key: secret, session_token: @environment["AWS_SESSION_TOKEN"])
      end

      def from_profile
        values = profile_values(@credentials_file)
        return unless values["aws_access_key_id"] && values["aws_secret_access_key"]

        AwsCredentials.new(access_key_id: values["aws_access_key_id"], secret_access_key: values["aws_secret_access_key"],
          session_token: values["aws_session_token"])
      end

      def from_container
        relative = @environment["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
        full = @environment["AWS_CONTAINER_CREDENTIALS_FULL_URI"]
        return unless relative || full

        uri = relative ? URI("http://169.254.170.2#{relative}") : URI(full)
        allowed = uri.host == "169.254.170.2" || %w[127.0.0.1 ::1 localhost].include?(uri.host)
        raise CredentialError, "AWS container credential endpoint is not an allowed local address" unless allowed && uri.scheme == "http"

        headers = {}
        token = @environment["AWS_CONTAINER_AUTHORIZATION_TOKEN"]
        token_file = @environment["AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"]
        token ||= File.read(token_file).strip if token_file && File.file?(token_file)
        headers["Authorization"] = token if token
        credential_json(@http_get.call(uri, headers:))
      end

      def from_instance_metadata
        return if @environment["AWS_EC2_METADATA_DISABLED"].to_s.casecmp?("true")

        base = URI("http://169.254.169.254/latest/")
        token = @http_get.call(URI.join(base, "api/token"), method: :put,
          headers: {"X-aws-ec2-metadata-token-ttl-seconds" => "21600"})
        headers = {"X-aws-ec2-metadata-token" => token}
        role = @http_get.call(URI.join(base, "meta-data/iam/security-credentials/"), headers:).strip
        return if role.empty?

        credential_json(@http_get.call(URI.join(base, "meta-data/iam/security-credentials/#{URI.encode_www_form_component(role)}"), headers:))
      rescue HTTPError
        nil
      end

      def credential_json(body)
        value = JSON.parse(body)
        AwsCredentials.new(access_key_id: value.fetch("AccessKeyId"), secret_access_key: value.fetch("SecretAccessKey"),
          session_token: value["Token"], expiration: value["Expiration"])
      rescue JSON::ParserError, KeyError => error
        raise CredentialError, "AWS credential endpoint returned an invalid response: #{error.message}"
      end

      def profile_values(path)
        return {} unless path && File.file?(path)

        section = nil
        File.foreach(path).each_with_object({}) do |line, result|
          stripped = line.strip
          if (match = stripped.match(/\A\[([^\]]+)\]\z/))
            section = match[1].sub(/\Aprofile\s+/, "")
          elsif section == @profile && (match = stripped.match(/\A([^#;=]+?)\s*=\s*(.*?)\s*\z/))
            result[match[1].strip] = match[2]
          end
        end
      end

      def config_file = @environment["AWS_CONFIG_FILE"] || File.expand_path("~/.aws/config")

      def http_get(uri, method: :get, headers: {})
        request = ((method == :put) ? Net::HTTP::Put : Net::HTTP::Get).new(uri)
        headers.each { |name, value| request[name] = value }
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) { |http| http.request(request) }
        raise HTTPError.new("Credential endpoint failed with HTTP #{response.code}", status: response.code.to_i) unless response.is_a?(Net::HTTPSuccess)

        response.body.to_s
      rescue *HTTPTransport::TRANSIENT_NETWORK_ERRORS => error
        raise HTTPError, "Credential endpoint failed (#{error.class})"
      end
    end

    # Resolves Vertex access tokens from explicit values, service-account ADC,
    # or the Google metadata server.
    class GoogleCredentialResolver
      TOKEN_URI = URI("https://oauth2.googleapis.com/token")
      SCOPE = "https://www.googleapis.com/auth/cloud-platform"

      def initialize(environment: ENV, access_token: nil, http_request: nil, clock: -> { Time.now.to_i })
        @environment = environment
        @access_token = access_token
        @http_request = http_request || method(:http_request)
        @clock = clock
        @mutex = Mutex.new
      end

      def call
        return @access_token unless @access_token.to_s.empty?

        @mutex.synchronize do
          return @cached_token if @cached_token && @expires_at && @expires_at > @clock.call + 60

          file = @environment["GOOGLE_APPLICATION_CREDENTIALS"]
          token, expires_in = file ? service_account_token(file) : metadata_token
          @cached_token = token
          @expires_at = @clock.call + Integer(expires_in || 3600)
          token
        end
      end

      private

      def service_account_token(path)
        document = JSON.parse(File.read(path))
        raise CredentialError, "Google application credentials must be a service_account" unless document["type"] == "service_account"

        now = @clock.call
        header = urlsafe(JSON.generate(alg: "RS256", typ: "JWT"))
        claim = urlsafe(JSON.generate(iss: document.fetch("client_email"), scope: SCOPE,
          aud: document["token_uri"] || TOKEN_URI.to_s, iat: now, exp: now + 3600))
        signature = OpenSSL::PKey::RSA.new(document.fetch("private_key")).sign(OpenSSL::Digest.new("SHA256"), "#{header}.#{claim}")
        assertion = "#{header}.#{claim}.#{urlsafe(signature)}"
        response = @http_request.call(URI(document["token_uri"] || TOKEN_URI.to_s), method: :post,
          headers: {"content-type" => "application/x-www-form-urlencoded"},
          body: URI.encode_www_form(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion:))
        token_json(response)
      rescue Errno::ENOENT, JSON::ParserError, KeyError, OpenSSL::PKey::PKeyError => error
        raise CredentialError, "Google service-account credentials are invalid: #{error.message}"
      end

      def metadata_token
        response = @http_request.call(
          URI("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"),
          method: :get,
          headers: {"Metadata-Flavor" => "Google"}, body: nil
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

      def http_request(uri, method:, headers:, body:)
        request_class = (method == :post) ? Net::HTTP::Post : Net::HTTP::Get
        request = request_class.new(uri)
        headers.each { |name, value| request[name] = value }
        request.body = body
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 5) { |http| http.request(request) }
        raise HTTPError.new("Google credential endpoint failed with HTTP #{response.code}", status: response.code.to_i) unless response.is_a?(Net::HTTPSuccess)

        response.body.to_s
      end
    end
  end
end
