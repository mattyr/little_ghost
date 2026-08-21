# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "async"
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

  def test_concurrent_refreshes_share_one_token_request
    resolver = LittleGhost::Providers::VertexAI::CredentialResolver.new(environment: {})
    entered = Queue.new
    release = Queue.new
    calls = 0
    results = []

    stub_http_client(lambda { |**|
      calls += 1
      entered << true
      release.pop
      JSON.generate(access_token: "token", expires_in: 3600)
    }) do
      Async do |task|
        task.async { results << resolver.call }
        entered.pop
        task.async { results << resolver.call }
        task.async do |child|
          child.sleep(0.02)
          release << true
        end
      end
    end

    assert_equal 1, calls
    assert_equal %w[token token], results
  ensure
    release << true if release && release.empty?
  end

  def test_concurrent_refresh_waiters_receive_the_same_failure_and_a_later_call_retries
    resolver = LittleGhost::Providers::VertexAI::CredentialResolver.new(environment: {})
    entered = Queue.new
    release = Queue.new
    failure = RuntimeError.new("refresh failed")
    calls = 0
    errors = []

    stub_http_client(lambda { |**|
      calls += 1
      if calls == 1
        entered << true
        release.pop
        raise failure
      end
      JSON.generate(access_token: "recovered", expires_in: 3600)
    }) do
      Async do |task|
        task.async do
          resolver.call
        rescue => error
          errors << error
        end
        entered.pop
        task.async do
          resolver.call
        rescue => error
          errors << error
        end
        task.async do |child|
          child.sleep(0.02)
          release << true
        end
      end

      assert_equal "recovered", resolver.call
    end

    assert_equal 2, calls
    assert_equal [failure, failure], errors
  ensure
    release << true if release && release.empty?
  end

  def test_refresh_waiter_honors_its_own_cancellation
    resolver = LittleGhost::Providers::VertexAI::CredentialResolver.new(environment: {})
    entered = Queue.new
    release = Queue.new
    token = LittleGhost::Support::CancellationToken.new
    waiter_error = nil

    stub_http_client(lambda { |**|
      entered << true
      release.pop
      JSON.generate(access_token: "token", expires_in: 3600)
    }) do
      Async do |task|
        task.async { resolver.call }
        entered.pop
        task.async do
          resolver.call(cancellation_token: token)
        rescue => error
          waiter_error = error
        end
        task.async do |child|
          child.sleep(0.02)
          token.cancel
          child.sleep(0.02)
          release << true
        end
      end
    end

    assert_instance_of LittleGhost::CancelledError, waiter_error
  ensure
    token&.cancel
    release << true if release && release.empty?
  end

  def test_owner_deadline_does_not_discard_a_token_for_an_unrelated_waiter
    resolver = LittleGhost::Providers::VertexAI::CredentialResolver.new(environment: {})
    entered = Queue.new
    release = Queue.new
    owner_error = nil
    waiter_result = nil
    calls = 0

    stub_http_client(lambda { |**arguments|
      calls += 1
      assert_nil arguments.fetch(:cancellation_token)
      assert_nil arguments.fetch(:deadline)
      entered << true
      release.pop
      JSON.generate(access_token: "shared-token", expires_in: 3600)
    }) do
      Async do |task|
        task.async do
          resolver.call(deadline: Time.now + 0.02)
        rescue => error
          owner_error = error
        end
        entered.pop
        task.async { waiter_result = resolver.call }
        task.async do |child|
          child.sleep(0.05)
          release << true
        end
      end
    end

    assert_instance_of LittleGhost::DeadlineExceededError, owner_error
    assert_equal "shared-token", waiter_result
    assert_equal 1, calls
  ensure
    release << true if release && release.empty?
  end
end
