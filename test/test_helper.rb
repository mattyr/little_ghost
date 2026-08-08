# frozen_string_literal: true

require "minitest/autorun"
require "little_ghost"

class TestRuntime
  def error_message(error, _run) = "Agent failed: #{error.class}"
  def service_name = "test"
end

module InstrumentationIsolation
  def before_setup
    LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    LittleGhost::Events.reporter = LittleGhost::Events::Reporter.new(listeners: [])
    super
  end
end

Minitest::Test.prepend(InstrumentationIsolation)

class TestInstrumentationSubscriber < LittleGhost::Instrumentation::Subscriber
  attr_reader :events

  def initialize(events = [], &listener)
    @events = events
    @listener = listener
  end

  def start(name, attributes) = deliver(:start, name, attributes)
  def finish(name, attributes) = deliver(:finish, name, attributes)
  def emit(name, attributes) = deliver(:emit, name, attributes)

  private

  def deliver(phase, name, attributes)
    @events << [phase, name, attributes]
    @listener&.call(phase, name, attributes)
  end
end

class TestTelemetryRecorder < LittleGhost::Instrumentation::Subscriber
  attr_reader :events

  def initialize(events = [])
    @events = events
  end

  def start(name, attributes) = record(:start, name, attributes)
  def finish(name, attributes) = record(:finish, name, attributes)
  def emit(name, attributes) = record(:emit, name, attributes)

  private

  def record(phase, name, attributes)
    lifecycle = (phase == :finish) ? :stop : phase
    event_name = (phase == :emit) ? name : :"#{name}_#{lifecycle}"
    events << [event_name, attributes]
  end
end

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
