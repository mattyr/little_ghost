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
      resolver = LittleGhost::Providers::VertexAI::CredentialResolver.new(
        environment: {"GOOGLE_APPLICATION_CREDENTIALS" => path},
        clock: -> { 1_700_000_000 }
      )

      stub_http_client(->(**) { JSON.generate(access_token: "token", expires_in: 3600) }) do |client|
        assert_equal "token", resolver.call
        assert_equal "token", resolver.call
        assert_equal 1, client.requests.length
        form = URI.decode_www_form(client.requests.first.fetch(:body)).to_h
        assert_equal "urn:ietf:params:oauth:grant-type:jwt-bearer", form.fetch("grant_type")
        assert_equal 3, form.fetch("assertion").split(".").length
      end
    end
  end
end
