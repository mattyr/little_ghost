# frozen_string_literal: true

require "tmpdir"
require "test_helper"

class DefaultModelRegistryTest < Minitest::Test
  CREDENTIAL_KEYS = %w[
    LITTLEGHOST_OPENROUTER_API_KEY
    LITTLEGHOST_OPENAI_API_KEY
    OPENROUTER_API_KEY
    OPENAI_API_KEY
  ].freeze

  class AnsweringProvider
    attr_reader :requests

    def initialize
      @requests = []
    end

    def stream(request)
      requests << request
      response = LittleGhost::ModelResponse.new(
        message: LittleGhost::Message.new(role: :assistant, content: "A practical first step"),
        stop_reason: :end_turn
      )
      [
        LittleGhost::StreamEvent.build(:message_start),
        LittleGhost::StreamEvent.build(:text_delta, text: response.message.text),
        LittleGhost::StreamEvent.build(:message_stop, response:)
      ].each
    end
  end

  def test_resolves_prefixed_openrouter_credentials_first
    with_credentials(
      "LITTLEGHOST_OPENROUTER_API_KEY" => "prefixed-openrouter",
      "LITTLEGHOST_OPENAI_API_KEY" => "prefixed-openai",
      "OPENROUTER_API_KEY" => "openrouter",
      "OPENAI_API_KEY" => "openai"
    ) do
      model = LittleGhost::DefaultModelRegistry.new.resolve("default")

      assert_equal :openrouter, model.provider_name
      assert_equal "openai/gpt-5.6-terra", model.id
      assert_equal "default", model.role
      assert_instance_of LittleGhost::Providers::OpenRouter, model.provider
    end
  end

  def test_prefers_prefixed_openai_over_unprefixed_openrouter
    with_credentials(
      "LITTLEGHOST_OPENAI_API_KEY" => "prefixed-openai",
      "OPENROUTER_API_KEY" => "openrouter"
    ) do
      model = LittleGhost::DefaultModelRegistry.new.resolve("default")

      assert_equal :openai, model.provider_name
      assert_equal "gpt-5.6-terra", model.id
      assert_instance_of LittleGhost::Providers::OpenAI, model.provider
    end
  end

  def test_prefers_unprefixed_openrouter_over_unprefixed_openai
    with_credentials(
      "OPENROUTER_API_KEY" => "openrouter",
      "OPENAI_API_KEY" => "openai"
    ) do
      model = LittleGhost::DefaultModelRegistry.new.resolve("default")

      assert_equal :openrouter, model.provider_name
      assert_equal "openai/gpt-5.6-terra", model.id
    end
  end

  def test_ignores_blank_credentials
    with_credentials(
      "LITTLEGHOST_OPENROUTER_API_KEY" => " ",
      "LITTLEGHOST_OPENAI_API_KEY" => "",
      "OPENROUTER_API_KEY" => "\t",
      "OPENAI_API_KEY" => "openai"
    ) do
      model = LittleGhost::DefaultModelRegistry.new.resolve("default")

      assert_equal :openai, model.provider_name
      assert_equal "gpt-5.6-terra", model.id
    end
  end

  def test_missing_credentials_fail_when_the_default_profile_is_resolved
    with_credentials do
      registry = LittleGhost::DefaultModelRegistry.new

      error = assert_raises(LittleGhost::ConfigurationError) { registry.resolve("default") }

      CREDENTIAL_KEYS.each { |key| assert_includes error.message, key }
      assert_includes error.message, "custom model registry"
    end
  end

  def test_class_ask_uses_the_default_registry_without_network_configuration
    provider = AnsweringProvider.new
    agent_class = Class.new(LittleGhost::Agent) do
      system_prompt "Turn a rough idea into a practical first step."
    end

    with_credentials("LITTLEGHOST_OPENAI_API_KEY" => "openai") do
      Dir.mktmpdir do |root|
        configuration = LittleGhost::Configuration.new(root:)
        LittleGhost::Providers::OpenAI.stub(:new, ->(**) { provider }) do
          run = LittleGhost.with_configuration(configuration) do
            agent_class.ask("Help me plan a launch")
          end

          assert run.completed?
          assert_equal "A practical first step", run.response
          assert_equal "Turn a rough idea into a practical first step.", provider.requests.first.messages.first.text
        end
      end
    end
  end

  def test_base_agent_ask_uses_the_default_system_prompt
    provider = AnsweringProvider.new

    with_credentials("LITTLEGHOST_OPENAI_API_KEY" => "openai") do
      Dir.mktmpdir do |root|
        configuration = LittleGhost::Configuration.new(root:)
        LittleGhost::Providers::OpenAI.stub(:new, ->(**) { provider }) do
          run = LittleGhost.with_configuration(configuration) do
            LittleGhost::Agent.ask("hi")
          end

          assert run.completed?
          assert_equal "A practical first step", run.response
          assert_equal "You are a helpful agent.", provider.requests.first.messages.first.text
        end
      end
    end
  end

  def test_class_ask_returns_a_failed_run_when_credentials_are_missing
    agent_class = Class.new(LittleGhost::Agent) do
      system_prompt "Answer."
    end

    with_credentials do
      Dir.mktmpdir do |root|
        run = LittleGhost.with_configuration(LittleGhost::Configuration.new(root:)) do
          agent_class.ask("Hello")
        end

        assert run.failed?
        assert_instance_of LittleGhost::ConfigurationError, run.error
        assert_includes run.error.message, "LITTLEGHOST_OPENROUTER_API_KEY"
      end
    end
  end

  private

  def with_credentials(values = {})
    previous = CREDENTIAL_KEYS.to_h { |key| [key, [ENV.key?(key), ENV[key]]] }
    CREDENTIAL_KEYS.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, (present, value)|
      present ? ENV[key] = value : ENV.delete(key)
    end
  end
end
