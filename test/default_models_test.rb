# frozen_string_literal: true

require "test_helper"

class DefaultModelsTest < Minitest::Test
  KEYS = %w[LITTLEGHOST_OPENROUTER_API_KEY LITTLEGHOST_OPENAI_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY].freeze

  def test_prefers_prefixed_openrouter_and_uses_terra
    with_credentials("LITTLEGHOST_OPENROUTER_API_KEY" => "key", "OPENAI_API_KEY" => "other") do
      model = LittleGhost::Models.new.resolve("default")

      assert_equal "openrouter:openai/gpt-5.6-terra", model.target.to_s
      assert_instance_of LittleGhost::Providers::OpenRouter, model.provider
    end
  end

  def test_missing_credentials_fail_when_resolved
    with_credentials do
      error = assert_raises(LittleGhost::CredentialError) { LittleGhost::Models.new.resolve("default") }

      KEYS.each { |key| assert_includes error.message, key }
      assert_includes error.message, "config/little_ghost/providers.yml"
    end
  end

  private

  def with_credentials(values = {})
    previous = KEYS.to_h { |key| [key, [ENV.key?(key), ENV[key]]] }
    KEYS.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, (present, value)| present ? ENV[key] = value : ENV.delete(key) }
  end
end
