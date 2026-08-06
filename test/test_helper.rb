# frozen_string_literal: true

require "minitest/autorun"
require "little_ghost"

class TestHarness < LittleGhost::Configuration
  def select_agent(value) = @test_agent_class = value

  def runtime(root: nil, agent: nil)
    self.root(root) if root
    @test_agent_class = agent if agent
    @test_runtime ||= LittleGhost::Runtime.new(configuration: self)
    resolve_test_agent_class
    @test_agent ||= @test_agent_class.new(runtime: @test_runtime) if agent_class_is?(LittleGhost::Agent)
    self
  end

  def build(**overrides)
    return build_runtime(**overrides) if @test_runtime

    values = settings.merge(overrides)
    @test_runtime = LittleGhost::Runtime.new(configuration: self, settings: values)
    resolve_test_agent_class
    @test_agent = @test_agent_class.new(runtime: @test_runtime) if agent_class_is?(LittleGhost::Agent)
    self
  end

  def build_agent(agent_class = @test_agent_class, run:, **options)
    runtime unless @test_runtime
    runtime_instance.build_agent(agent_class, run:, **options)
  end

  def agent_instance
    runtime unless @test_runtime
    @test_agent || raise("test agent has not been selected")
  end

  def agent_class
    runtime unless @test_runtime
    @test_agent_class
  end

  def runtime_instance
    @test_runtime || raise("test runtime has not been built")
  end

  def instrumentation(value = :__read__)
    return runtime_instance.instrumentation if value == :__read__ && @test_runtime

    super
  end

  def session_store(value = :__read__)
    return runtime_instance.session_store if value == :__read__ && @test_runtime

    super
  end

  def build_runtime(**overrides)
    values = runtime_instance.settings.merge(overrides)
    values[:root] = runtime_instance.send(:canonical_application_root, values.fetch(:root))
    values[:loader] = runtime_instance.loader unless overrides.key?(:loader) || overrides.key?(:root)
    copy = self.class.new
    copy.instance_variable_set(:@configuration_values, values)
    copy.instance_variable_set(:@test_agent_class, @test_agent_class)
    copy.instance_variable_set(:@test_runtime, LittleGhost::Runtime.new(configuration: copy, settings: values))
    copy.instance_variable_set(:@test_agent, @test_agent_class.new(runtime: copy.runtime_instance)) if copy.agent_class_is?(LittleGhost::Agent)
    copy
  end

  def resolve_test_agent_class
    @test_agent_class = runtime_instance.resolve_agent(@test_agent_class) if @test_agent_class.is_a?(String) || @test_agent_class.is_a?(Symbol)
  end

  def agent_class_is?(base)
    @test_agent_class.is_a?(Class) && @test_agent_class <= base
  end

  def method_missing(name, *args, **options, &block)
    return super unless runtime_instance.respond_to?(name)

    runtime_instance.public_send(name, *args, **options, &block)
  end

  def respond_to_missing?(name, include_private = false)
    runtime_instance.respond_to?(name, include_private) || super
  end
end
