# frozen_string_literal: true

require "json"
require "time"
require "uri"

module LittleGhost
  module Providers
    class Bedrock < Base
      Credentials = Data.define(:access_key_id, :secret_access_key, :session_token, :expiration) do # :nodoc:
        def initialize(access_key_id:, secret_access_key:, session_token: nil, expiration: nil)
          raise CredentialError, "AWS access key ID and secret access key are required" if access_key_id.to_s.empty? || secret_access_key.to_s.empty?

          super(access_key_id: access_key_id.to_s, secret_access_key: secret_access_key.to_s,
                session_token: session_token&.to_s, expiration: expiration && Time.parse(expiration.to_s))
        end
      end

      # Resolves common AWS credentials without depending on an AWS SDK.
      class CredentialResolver
        def initialize(environment: ENV, profile: nil, credentials_file: nil)
          @environment = environment
          @profile = profile || environment["AWS_PROFILE"] || "default"
          @credentials_file = credentials_file || environment["AWS_SHARED_CREDENTIALS_FILE"] || File.expand_path("~/.aws/credentials")
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

          Credentials.new(access_key_id: key, secret_access_key: secret, session_token: @environment["AWS_SESSION_TOKEN"])
        end

        def from_profile
          values = profile_values(@credentials_file)
          return unless values["aws_access_key_id"] && values["aws_secret_access_key"]

          Credentials.new(access_key_id: values["aws_access_key_id"], secret_access_key: values["aws_secret_access_key"],
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
          credential_json(http_client.request(uri:, headers:, allow_insecure_http: true))
        end

        def from_instance_metadata
          return if @environment["AWS_EC2_METADATA_DISABLED"].to_s.casecmp?("true")

          base = URI("http://169.254.169.254/latest/")
          token = http_client.request(uri: URI.join(base, "api/token"), method: :put,
            headers: {"X-aws-ec2-metadata-token-ttl-seconds" => "21600"}, allow_insecure_http: true)
          headers = {"X-aws-ec2-metadata-token" => token}
          role = http_client.request(uri: URI.join(base, "meta-data/iam/security-credentials/"), headers:,
            allow_insecure_http: true).strip
          return if role.empty?

          credential_json(http_client.request(
            uri: URI.join(base, "meta-data/iam/security-credentials/#{URI.encode_www_form_component(role)}"),
            headers:,
            allow_insecure_http: true
          ))
        rescue HTTPError
          nil
        end

        def credential_json(body)
          value = JSON.parse(body)
          Credentials.new(access_key_id: value.fetch("AccessKeyId"), secret_access_key: value.fetch("SecretAccessKey"),
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

        def http_client = Support::HTTPClient.new(open_timeout: 1, read_timeout: 1, max_response_bytes: 1024 * 1024)
      end
    end
  end
end
