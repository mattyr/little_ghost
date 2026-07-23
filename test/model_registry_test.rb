# frozen_string_literal: true

require "test_helper"

class ModelRegistryTest < Minitest::Test
  class RecordingProvider
    attr_reader :request

    def stream(request)
      @request = request
      [].each
    end
  end

  def test_resolves_profiles_and_invocation_overrides_into_an_executable_model
    provider = RecordingProvider.new
    received = nil
    registry = LittleGhost::ModelRegistry.new
      .provider(:test) do |**arguments|
        received = arguments
        provider
      end
      .profile("main", provider: :test, model: "small", settings: {temperature: 0.1}, metadata: {family: "base"})
      .profile("explore", inherit: "main", settings: {max_tokens: 100})
    invocation = LittleGhost::Invocation.new(
      message: "hello",
      model_profiles: {"explore" => {"model" => "large", "parameters" => {"temperature" => 0.4}}}
    )

    model = registry.resolve("explore", invocation:, context: :run, request_id: "request")

    assert_same provider, model.provider
    assert_equal :test, model.provider_name
    assert_equal "large", model.id
    assert_equal({temperature: 0.4, max_tokens: 100}, model.settings)
    assert_equal(
      {family: "base", provider: :test, model_id: "large", model_role: "explore"},
      model.metadata
    )
    assert_equal "explore", model.role
    assert_equal "large", received.fetch(:model)
    assert_equal "explore", received.fetch(:role)
    assert_equal({temperature: 0.4, max_tokens: 100}, received.fetch(:settings))
    assert_equal({family: "base"}, received.fetch(:metadata))
    assert_same invocation, received.fetch(:invocation)
    assert_equal :run, received.fetch(:context)
    assert_equal "request", received.fetch(:request_id)
  end

  def test_model_applies_profile_settings_before_request_overrides
    provider = RecordingProvider.new
    model = LittleGhost::Model.new(
      provider:,
      provider_name: :test,
      model: "small",
      settings: {temperature: 0.1, max_tokens: 100},
      role: :main
    )
    request = LittleGhost::ModelRequest.new(messages: [], settings: {temperature: 0.7})

    model.stream(request).to_a

    assert_equal({temperature: 0.7, max_tokens: 100}, provider.request.settings)
  end

  def test_model_rejects_attachments_outside_its_declared_input_modalities
    provider = RecordingProvider.new
    model = LittleGhost::Model.new(
      provider:, provider_name: :test, model: "text-only",
      metadata: {input_modalities: ["text"]}
    )
    request = LittleGhost::ModelRequest.new(messages: [
      LittleGhost::Message.new(
        role: :user,
        content: [LittleGhost::Content::Image.new(data: "image", media_type: "image/png")]
      )
    ])

    error = assert_raises(LittleGhost::UnsupportedInputError) { model.stream(request).to_a }

    assert_includes error.message, "does not support image attachments"
    assert_nil provider.request
  end

  def test_model_identity_metadata_cannot_be_overridden_by_a_profile
    model = LittleGhost::Model.new(
      provider: RecordingProvider.new,
      provider_name: :test,
      model: "canonical-model",
      role: :main,
      metadata: {
        "provider" => :other,
        "model_id" => "other-model",
        "model_role" => "other-role",
        "family" => "kept"
      }
    )

    assert_equal(
      {"family" => "kept", :provider => :test, :model_id => "canonical-model", :model_role => "main"},
      model.metadata
    )
  end

  def test_rejects_circular_profile_inheritance
    registry = LittleGhost::ModelRegistry.new
      .profile("one", inherit: "two")
      .profile("two", inherit: "one")

    error = assert_raises(LittleGhost::ConfigurationError) { registry.resolve("one") }

    assert_includes error.message, "Circular model profile inheritance"
  end

  def test_falls_back_to_the_longest_registered_dotted_role
    registry = LittleGhost::ModelRegistry.new
      .provider(:test) { |**| RecordingProvider.new }
      .profile("engineering", provider: :test, model: "broad")
      .profile("engineering.subagent", provider: :test, model: "specialized", metadata: {tier: "subagent"})
    invocation = LittleGhost::Invocation.new(
      message: "hello",
      model_profiles: {"engineering.subagent.review" => {"model" => "overridden"}}
    )

    model = registry.resolve("engineering.subagent.review", invocation:)

    assert_equal "overridden", model.id
    assert_equal "engineering.subagent.review", model.role
    assert_equal "subagent", model.metadata.fetch(:tier)
  end

  def test_dotted_roles_layer_parent_and_exact_invocation_profiles
    registry = LittleGhost::ModelRegistry.new
      .provider(:test) { |**| RecordingProvider.new }
      .profile("engineering", provider: :test, model: "default", settings: {temperature: 0.2})
      .profile("engineering.subagent", inherit: "engineering", settings: {max_tokens: 1_000})
    invocation = LittleGhost::Invocation.new(
      message: "hello",
      model_profiles: {
        "engineering" => {"model_id" => "configured", "parameters" => {"temperature" => 0.4}},
        "engineering.subagent.review" => {"parameters" => {"max_tokens" => 2_000}}
      }
    )

    model = registry.resolve("engineering.subagent.review", invocation:)

    assert_equal "configured", model.id
    assert_equal({temperature: 0.4, max_tokens: 2_000}, model.settings)
  end

  def test_configuration_errors_are_specific_and_factory_errors_are_not_masked
    missing = LittleGhost::ModelRegistry.new.profile("main", model: "small")
    error = assert_raises(LittleGhost::ConfigurationError) { missing.resolve("main") }
    assert_includes error.message, "does not define a provider"

    registry = LittleGhost::ModelRegistry.new
      .provider(:test) { |**| raise KeyError, "factory failure" }
      .profile("main", provider: :test, model: "small")

    error = assert_raises(KeyError) { registry.resolve("main") }
    assert_equal "factory failure", error.message
  end

  def test_symbol_profile_names_are_normalized_to_strings
    registry = LittleGhost::ModelRegistry.new
      .provider(:test) { |**| RecordingProvider.new }
      .profile(:main, provider: :test, model: "small")

    assert_equal "main", registry.resolve(:main).role
  end
end
