# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"

class ModelResolverTest < Minitest::Test
  class RecordingProvider < LittleGhost::Providers::Base
    attr_reader :request

    def stream(request)
      @request = request
      [].each
    end
  end

  def test_loads_separate_provider_and_model_files_and_resolves_inheritance
    with_configuration(
      providers: <<~YAML,
        providers:
          primary:
            adapter: test
            api_key: <%= ENV.fetch("MODELS_TEST_KEY") %>
      YAML
      models: <<~YAML
        default_model: main
        models:
          main:
            target: primary:vendor/model:version
            settings:
              temperature: 0.1
          main.research:
            inherits: main
            settings:
              max_tokens: 100
      YAML
    ) do |directory|
      provider = RecordingProvider.new
      previous = ENV["MODELS_TEST_KEY"]
      ENV["MODELS_TEST_KEY"] = "secret"
      configuration = LittleGhost::Models::Configuration.new(directory:)
      models = LittleGhost::ModelResolver.new(configuration:, provider_adapters: {"test" => ->(**) { provider }})

      model = models.resolve("main.research.review")

      assert_equal "primary:vendor/model:version", model.target.to_s
      assert_equal "vendor/model:version", model.model_id
      assert_equal({temperature: 0.1, max_tokens: 100}, model.settings)
      assert_equal "main.research.review", model.role
      assert_same provider, model.provider
    ensure
      previous ? ENV["MODELS_TEST_KEY"] = previous : ENV.delete("MODELS_TEST_KEY")
    end
  end

  def test_invocation_settings_overlay_profiles_without_legacy_parameter_aliases
    with_configuration(
      providers: "providers:\n  test:\n    adapter: test\n",
      models: <<~YAML
        models:
          main:
            target: test:model
            settings:
              temperature: 0.1
      YAML
    ) do |directory|
      models = LittleGhost::ModelResolver.new(
        directory:,
        provider_adapters: {"test" => ->(**) { RecordingProvider.new }}
      )
      invocation = LittleGhost::Invocation.new(
        message: "hello",
        model_configuration: {"profiles" => {"main" => {"settings" => {"temperature" => 0.4}}}}
      )

      model = models.resolve("main", invocation:)

      assert_equal({temperature: 0.4}, model.settings)
    end
  end

  def test_invocation_request_options_cannot_replace_provider_connections
    with_configuration(
      providers: "providers:\n  test:\n    adapter: test\n    api_key: trusted-secret\n",
      models: "models:\n  main:\n    target: test:model\n"
    ) do |directory|
      models = LittleGhost::ModelResolver.new(
        directory:,
        provider_adapters: {"test" => ->(**) { RecordingProvider.new }}
      )
      invocation = LittleGhost::Invocation.new(
        message: "hello",
        model_configuration: {"profiles" => {"main" => {"request" => {"base_url" => "https://attacker.example/"}}}}
      )

      error = assert_raises(LittleGhost::ConfigurationError) { models.resolve("main", invocation:) }

      assert_includes error.message, "base_url"
    end
  end

  def test_invocation_details_snapshot_replaces_local_catalog_facts
    with_configuration(
      providers: "providers:\n  test:\n    adapter: test\n",
      models: "models:\n  main:\n    target: test:model\n"
    ) do |directory|
      models = LittleGhost::ModelResolver.new(
        directory:,
        provider_adapters: {"test" => ->(**) { RecordingProvider.new }}
      )
      invocation = LittleGhost::Invocation.new(
        message: "hello",
        model_configuration: {"profiles" => {"main" => {"details" => {
          "target" => "test:model", "context_window" => 321, "provenance" => {"context_window" => "run-snapshot"}
        }}}}
      )

      model = models.resolve("main", invocation:)

      assert_equal 321, model.details.context_window
      assert_equal "run-snapshot", model.details.provenance.fetch(:context_window)
    end
  end

  def test_conventional_retries_request_option_maps_to_provider_max_retries
    with_configuration(
      providers: "providers:\n  test:\n    adapter: test\n",
      models: "models:\n  main:\n    target: test:model\n    request:\n      retries: 4\n"
    ) do |directory|
      received = nil
      models = LittleGhost::ModelResolver.new(
        directory:,
        provider_adapters: {"test" => lambda { |configuration:, **|
          received = configuration
          RecordingProvider.new
        }}
      )

      models.resolve("main")

      assert_equal 4, received.fetch(:max_retries)
      refute received.key?(:retries)
    end
  end

  def test_arbitrary_canonical_target_resolves_with_unknown_details
    with_configuration(
      providers: "providers:\n  gateway:\n    adapter: test\n",
      models: "models:\n  main:\n    target: gateway:known\n"
    ) do |directory|
      models = LittleGhost::ModelResolver.new(directory:, provider_adapters: {"test" => ->(**) { RecordingProvider.new }})

      model = models.resolve("gateway:released-today")

      refute model.details.known?
      assert_equal "released-today", model.model_id
    end
  end

  def test_catalog_precedence_and_failed_refresh_preserve_last_good_data
    source = Class.new(LittleGhost::Models::Catalog::Source).new(name: "test")
    calls = 0
    source.define_singleton_method(:refresh) do |target:|
      calls += 1
      raise "offline" if calls == 2

      {target.to_s => {context_window: 200, pricing: {input: 1.0}, observed_at: "2026-08-12T00:00:00Z"}}
    end
    catalog = LittleGhost::Models::Catalog.new(
      overrides: {"openai:gpt-5.6-terra" => {context_window: 300}},
      sources: [source]
    )

    result = catalog.refresh!(target: "openai:gpt-5.6-terra")
    details = catalog.details("openai:gpt-5.6-terra")
    failed = catalog.refresh!(target: "openai:gpt-5.6-terra")

    assert_empty result.fetch(:errors)
    assert_equal 300, details.context_window
    assert_equal({input: 1.0}, details.pricing)
    assert_equal 1, failed.fetch(:errors).length
    assert_equal({input: 1.0}, catalog.details("openai:gpt-5.6-terra").pricing)
  end

  def test_bundled_catalog_has_normalized_pricing_for_atlas_defaults
    catalog = LittleGhost::Models::Catalog.new

    main = catalog.details("openrouter:google/gemini-3.5-flash")
    engineering = catalog.details("openrouter:z-ai/glm-5.2")

    assert_equal 1.5, main.pricing.fetch(:input)
    assert_equal 9, main.pricing.fetch(:output)
    assert_equal 0.5, engineering.pricing.fetch(:input)
    assert_equal 3.15, engineering.pricing.fetch(:output)
  end

  def test_models_dev_source_targets_named_provider_connection
    response = JSON.generate(
      "openrouter" => {
        "models" => {
          "new/model" => {
            "limit" => {"context" => 123, "output" => 45},
            "cost" => {"input" => 1.25, "output" => 2.5},
            "modalities" => {"input" => ["text"], "output" => ["text"]}
          }
        }
      }
    )
    source = LittleGhost::Models::Catalog::ModelsDevSource.new(provider_adapters: {"router" => "openrouter"})
    records = stub_http_client(->(**) { response }) do
      source.refresh(target: LittleGhost::Models::Target.parse("router:new/model"))
    end

    assert_equal 123, records.dig("router:new/model", :context_window)
    assert_equal 1.25, records.dig("router:new/model", :pricing, "input")
  end

  def test_requires_both_configuration_files
    Dir.mktmpdir do |root|
      directory = File.join(root, "config/little_ghost")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "providers.yml"), "providers: {}\n")

      error = assert_raises(LittleGhost::ConfigurationError) { LittleGhost::Models::Configuration.new(directory:) }

      assert_includes error.message, "models.yml"
    end
  end

  def test_model_metadata_does_not_preflight_reject_attachments
    provider = RecordingProvider.new
    details = LittleGhost::Models::Details.new(target: "test:text", attributes: {input_modalities: ["text"]})
    model = LittleGhost::Model.new(provider:, target: "test:text", details:)
    request = LittleGhost::ModelRequest.new(messages: [
      LittleGhost::Message.new(role: :user, content: [LittleGhost::Content::Image.new(data: "image", media_type: "image/png")])
    ])

    model.stream(request).to_a

    assert_equal request.messages, provider.request.messages
  end

  def test_provider_credentials_are_resolved_at_model_construction
    with_configuration(
      providers: "providers:\n  router:\n    adapter: test\n",
      models: "models:\n  main:\n    target: router:model\n"
    ) do |directory|
      received = nil
      models = LittleGhost::ModelResolver.new(
        directory:,
        credential_resolver: ->(provider:, **_context) { {api_key: "resolved-#{provider}"} },
        provider_adapters: {"test" => lambda { |configuration:, **|
          received = configuration
          RecordingProvider.new
        }}
      )

      models.resolve("main")

      assert_equal "resolved-router", received.fetch(:api_key)
    end
  end

  private

  def with_configuration(providers:, models:)
    Dir.mktmpdir do |root|
      directory = File.join(root, "config/little_ghost")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "providers.yml"), providers)
      File.write(File.join(directory, "models.yml"), models)
      yield directory
    end
  end
end
