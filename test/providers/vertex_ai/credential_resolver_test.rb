# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"

class VertexAICredentialResolverTest < Minitest::Test
  def test_service_account_signs_and_caches_token
    Dir.mktmpdir do |root|
      key = OpenSSL::PKey::RSA.generate(1024)
      path = File.join(root, "service-account.json")
      File.write(path, JSON.generate(type: "service_account", client_email: "service@example.test", private_key: key.to_pem,
        token_uri: "https://oauth2.example.test/token"))
      requests = []
      resolver = LittleGhost::Providers::VertexAI::CredentialResolver.new(
        environment: {"GOOGLE_APPLICATION_CREDENTIALS" => path},
        clock: -> { 1_700_000_000 },
        http_request: lambda do |uri, method:, headers:, body:, **|
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
