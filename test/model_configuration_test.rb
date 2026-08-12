# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"

class ModelConfigurationTest < Minitest::Test
  class RecordingProvider < LittleGhost::Providers::Base
    def stream(_request) = [].each
  end

  def test_provider_configuration_normalizes_and_freezes_connections
    input = {primary: {adapter: :test, nested: {token: +"secret"}}}

    configuration = LittleGhost::Providers::Configuration.new(input)
    input[:primary][:nested][:token].replace("changed")

    assert_equal "test", configuration.connections.dig("primary", "adapter")
    assert_equal "secret", configuration.connections.dig("primary", "nested", "token")
    assert configuration.connections.frozen?
    assert configuration.connections.fetch("primary").frozen?
    assert configuration.connections.dig("primary", "nested").frozen?
  end

  def test_provider_configuration_resolves_credentials_lazily
    provider_configuration = Class.new(LittleGhost::Providers::Configuration) do
      attr_reader :requests

      def initialize
        @requests = []
        super(primary: {adapter: :test})
      end

      def credentials(**request)
        requests << request
        {api_key: "resolved"}
      end
    end.new
    received = nil
    configuration = LittleGhost::Configuration.new
    configuration.providers = provider_configuration
    configuration.models = {main: {target: "primary:model"}}
    configuration.provider_adapter("test", lambda { |configuration:, **|
      received = configuration
      RecordingProvider.new
    })

    configuration.model_resolver.resolve("main")

    assert_equal "resolved", received.fetch(:api_key)
    request = provider_configuration.requests.fetch(0)
    assert_equal 1, provider_configuration.requests.length
    assert_equal "primary", request.fetch(:provider)
    assert_equal "test", request.fetch(:adapter)
    assert_equal({"adapter" => "test"}, request.fetch(:configuration))
  end

  def test_explicit_credential_resolver_overrides_provider_configuration
    provider_configuration = Class.new(LittleGhost::Providers::Configuration) do
      def credentials(**)
        raise "provider credential resolver was called"
      end
    end.new(primary: {adapter: :test})
    received = nil
    configuration = LittleGhost::Configuration.new
    configuration.providers = provider_configuration
    configuration.models = {main: {target: "primary:model"}}
    configuration.provider_credentials ->(**) { {api_key: "explicit"} }
    configuration.provider_adapter("test", lambda { |configuration:, **|
      received = configuration
      RecordingProvider.new
    })

    configuration.model_resolver.resolve("main")

    assert_equal "explicit", received.fetch(:api_key)
  end

  def test_inline_sections_take_precedence_over_conventional_files
    with_root(
      providers: "providers:\n  file:\n    adapter: missing\n",
      models: "default_model: file\nmodels:\n  file:\n    target: file:model\n"
    ) do |root|
      configuration = LittleGhost::Configuration.new(root:)
      configuration.providers = {inline: {adapter: :test}}
      configuration.models = {inline: {target: "inline:model"}}
      configuration.default_model = :inline
      configuration.provider_adapter("test", ->(**) { RecordingProvider.new })

      resolver = configuration.model_resolver

      assert_equal "inline", resolver.default_model
      assert_equal "inline:model", resolver.resolve("inline").target.to_s
    end
  end

  def test_explicit_empty_providers_do_not_load_the_conventional_file
    with_root(
      providers: "providers:\n  file:\n    adapter: missing\n",
      models: "models:\n  default:\n    target: file:model\n"
    ) do |root|
      configuration = LittleGhost::Configuration.new(root:)
      configuration.providers = {}
      configuration.models = {default: {target: "missing:model"}}

      error = assert_raises(LittleGhost::ConfigurationError) do
        configuration.model_resolver.resolve("default")
      end

      assert_includes error.message, "unknown provider missing"
    end
  end

  def test_provider_and_model_files_are_loaded_independently
    Dir.mktmpdir do |provider_root|
      Dir.mktmpdir do |model_root|
        providers_path = write(provider_root, "providers.yml", "providers:\n  primary:\n    adapter: test\n")
        models_path = write(model_root, "models.yml", "default_model: main\nmodels:\n  main:\n    target: primary:model\n")
        configuration = LittleGhost::Configuration.new(root: provider_root)
        configuration.providers_path = providers_path
        configuration.models_path = models_path
        configuration.provider_adapter("test", ->(**) { RecordingProvider.new })

        assert_equal "primary:model", configuration.model_resolver.resolve("main").target.to_s
        assert_equal "main", configuration.model_resolver.default_model
      end
    end
  end

  def test_absent_conventional_files_use_zero_configuration_defaults
    with_credentials("LITTLEGHOST_OPENAI_API_KEY" => "key") do
      Dir.mktmpdir do |root|
        resolver = LittleGhost::Configuration.new(root:).model_resolver

        assert_equal "openai:gpt-5.6-luna", resolver.resolve("default").target.to_s
      end
    end
  end

  def test_explicit_missing_paths_raise
    Dir.mktmpdir do |root|
      configuration = LittleGhost::Configuration.new(root:)
      configuration.providers_path = File.join(root, "missing.yml")

      error = assert_raises(LittleGhost::ConfigurationError) { configuration.model_resolver }

      assert_includes error.message, "missing.yml"
    end
  end

  def test_custom_resolver_receives_providers_and_owns_its_profiles_and_default
    resolver_class = Class.new(LittleGhost::ModelResolver) do
      def initialize(providers:, provider_adapters:, catalog_sources:, credential_resolver:)
        super(
          providers:,
          profiles: {owned: {target: "primary:model"}},
          default_model: :owned,
          provider_adapters:,
          catalog_sources:,
          credential_resolver:
        )
      end
    end
    configuration = LittleGhost::Configuration.new
    configuration.providers = LittleGhost::Providers::Configuration.new(primary: {adapter: :test})
    configuration.provider_adapter("test", ->(**) { RecordingProvider.new })
    configuration.model_resolver = resolver_class

    assert_equal "primary:model", configuration.model_resolver.resolve("owned").target.to_s
    assert_equal "owned", configuration.settings.fetch(:default_model)
  end

  def test_model_resolver_requires_a_subclass
    error = assert_raises(ArgumentError) do
      LittleGhost::Configuration.new.model_resolver = LittleGhost::ModelResolver.new
    end

    assert_includes error.message, "subclass"
  end

  private

  CREDENTIAL_KEYS = LittleGhost::ModelResolver::DEFAULT_CREDENTIALS.map(&:first).freeze

  def with_root(providers:, models:)
    Dir.mktmpdir do |root|
      write(root, "config/little_ghost/providers.yml", providers)
      write(root, "config/little_ghost/models.yml", models)
      yield root
    end
  end

  def write(root, path, contents)
    full_path = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, contents)
    full_path
  end

  def with_credentials(values)
    previous = CREDENTIAL_KEYS.to_h { |key| [key, [ENV.key?(key), ENV[key]]] }
    CREDENTIAL_KEYS.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, (present, value)| present ? ENV[key] = value : ENV.delete(key) }
  end
end
