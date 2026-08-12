# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"

class CloudCredentialsTest < Minitest::Test
  def test_aws_environment_credentials_take_precedence
    environment = {
      "AWS_ACCESS_KEY_ID" => "environment-key",
      "AWS_SECRET_ACCESS_KEY" => "environment-secret",
      "AWS_SESSION_TOKEN" => "environment-token"
    }

    credentials = LittleGhost::Providers::AwsCredentialResolver.new(environment:).call

    assert_equal "environment-key", credentials.access_key_id
    assert_equal "environment-secret", credentials.secret_access_key
    assert_equal "environment-token", credentials.session_token
  end

  def test_aws_selected_shared_credentials_file_and_region
    Dir.mktmpdir do |root|
      credentials_path = File.join(root, "credentials")
      config_path = File.join(root, "config")
      File.write(credentials_path, "[staging]\naws_access_key_id = profile-key\naws_secret_access_key = profile-secret\naws_session_token = profile-token\n")
      File.write(config_path, "[profile staging]\nregion = us-west-2\n")
      environment = {"AWS_PROFILE" => "staging", "AWS_SHARED_CREDENTIALS_FILE" => credentials_path, "AWS_CONFIG_FILE" => config_path,
                     "AWS_EC2_METADATA_DISABLED" => "true"}
      resolver = LittleGhost::Providers::AwsCredentialResolver.new(environment:)

      assert_equal "profile-key", resolver.call.access_key_id
      assert_equal "us-west-2", resolver.region
    end
  end

  def test_aws_container_endpoint_rejects_untrusted_hosts
    resolver = LittleGhost::Providers::AwsCredentialResolver.new(
      environment: {"AWS_CONTAINER_CREDENTIALS_FULL_URI" => "http://example.com/credentials"},
      http_get: ->(*) { flunk "must not request" }
    )

    error = assert_raises(LittleGhost::CredentialError) { resolver.call }

    assert_includes error.message, "allowed local address"
  end

  def test_google_service_account_signs_and_caches_token
    Dir.mktmpdir do |root|
      key = OpenSSL::PKey::RSA.generate(1024)
      path = File.join(root, "service-account.json")
      File.write(path, JSON.generate(type: "service_account", client_email: "service@example.test", private_key: key.to_pem,
        token_uri: "https://oauth2.example.test/token"))
      requests = []
      resolver = LittleGhost::Providers::GoogleCredentialResolver.new(
        environment: {"GOOGLE_APPLICATION_CREDENTIALS" => path},
        clock: -> { 1_700_000_000 },
        http_request: lambda do |uri, method:, headers:, body:|
          requests << [uri, method, headers, URI.decode_www_form(body).to_h]
          JSON.generate(access_token: "token", expires_in: 3600)
        end
      )

      assert_equal "token", resolver.call
      assert_equal "token", resolver.call
      assert_equal 1, requests.length
      assert_equal "urn:ietf:params:oauth:grant-type:jwt-bearer", requests.first.last.fetch("grant_type")
      assert_equal 3, requests.first.last.fetch("assertion").split(".").length
    end
  end
end
