# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"

class ComponentTest < Minitest::Test
  class Invocation < LittleGhost::Invocation; end

  class RecordingModel
    attr_reader :requests

    def initialize
      @requests = []
    end

    def stream(request)
      @requests << request
      response = LittleGhost::ModelResponse.new(
        message: LittleGhost::Message.new(role: :assistant, content: "done"),
        stop_reason: :end_turn,
        usage: LittleGhost::Usage.new
      )
      [LittleGhost::StreamEvent.build(:message_stop, response:)].each
    end
  end

  def test_components_load_conventional_agents_and_tools
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        write(application_root, "app/agents/component_loading/main_agent.rb",
          "module ComponentLoading; class MainAgent < LittleGhost::Agent; system_prompt 'main'; end; end")
        write(component_root, "app/agents/component_loading/helper_agent.rb",
          "module ComponentLoading; class HelperAgent < LittleGhost::Agent; end; end")
        write(component_root, "app/tools/component_loading/echo_tool.rb",
          "module ComponentLoading; class EchoTool < LittleGhost::Tool; tool_name 'echo'; end; end")
        application = build_application(application_root, component_root, "ComponentLoading::MainAgent")

        instance = application.boot!

        assert_equal ComponentLoading::HelperAgent, instance.components.first.loader.constant("ComponentLoading::HelperAgent")
        assert_equal "ComponentLoading::EchoTool", ComponentLoading::EchoTool.name
        assert_equal "echo", ComponentLoading::EchoTool.tool_name
      ensure
        remove_constant(:ComponentLoading)
      end
    end
  end

  def test_namespaced_application_resolves_a_namespaced_agent
    Dir.mktmpdir do |application_root|
      write(application_root, "app/agents/example/agent.rb",
        "module Example; class Agent < LittleGhost::Agent; end; end")
      write(application_root, "app/prompts/example/system.erb", "namespaced prompt")
      Object.const_set(:Example, Module.new)
      application = Class.new(LittleGhost::Application)
      Example.const_set(:Application, application)
      application.root application_root
      model = RecordingModel.new
      application.models models_for(model)

      instance = application.boot!
      application.call(message: "hello")

      assert_equal Example::Agent, instance.instance_variable_get(:@agent_class)
      assert_equal "namespaced prompt", model.requests.first.messages.first.text
      assert_equal "hello", model.requests.first.messages.last.text
    ensure
      remove_constant(:Example)
    end
  end

  def test_named_application_resolves_a_root_agent
    Dir.mktmpdir do |application_root|
      write(application_root, "app/agents/convention_main_agent.rb",
        "class ConventionMainAgent < LittleGhost::Agent; system_prompt 'main'; end")
      Object.const_set(:ApplicationNamespace, Module.new)
      application = Class.new(LittleGhost::Application)
      ApplicationNamespace.const_set(:ConventionMainApplication, application)
      application.root application_root
      application.models models_for(RecordingModel.new)

      instance = application.boot!

      assert_equal ConventionMainAgent, instance.instance_variable_get(:@agent_class)
    ensure
      remove_constant(:ApplicationNamespace)
      remove_constant(:ConventionMainAgent)
    end
  end

  def test_all_component_autoloads_are_installed_before_files_are_evaluated
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |first_root|
        Dir.mktmpdir do |second_root|
          write(application_root, "app/agents/interdependent_component/main_agent.rb",
            "module InterdependentComponent; class MainAgent < LittleGhost::Agent; system_prompt SharedPrompt::TEXT; end; end")
          write(first_root, "app/agents/interdependent_component/helper_agent.rb",
            "module InterdependentComponent; class HelperAgent < LittleGhost::Agent; system_prompt LaterPrompt::TEXT; end; end")
          write(second_root, "app/tools/interdependent_component/shared_prompt.rb",
            "module InterdependentComponent; module SharedPrompt; TEXT = 'shared'; end; end")
          write(second_root, "app/tools/interdependent_component/later_prompt.rb",
            "module InterdependentComponent; module LaterPrompt; TEXT = 'later'; end; end")
          application = Class.new(LittleGhost::Application)
          application.root application_root
          application.agent "InterdependentComponent::MainAgent"
          application.invocation Invocation
          application.models models_for(RecordingModel.new)
          application.component LittleGhost::Component.new(root: first_root)
          application.component LittleGhost::Component.new(root: second_root)

          application.boot!

          assert_equal "shared", InterdependentComponent::MainAgent.system_prompt
          assert_equal "later", InterdependentComponent::HelperAgent.system_prompt
        ensure
          remove_constant(:InterdependentComponent)
        end
      end
    end
  end

  def test_application_prompts_override_component_fallbacks
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        write(application_root, "app/agents/component_prompts/main_agent.rb",
          "module ComponentPrompts; class MainAgent < LittleGhost::Agent; end; end")
        write(component_root, "app/prompts/component_prompts/main/system.erb", "component prompt")
        write(application_root, "app/prompts/component_prompts/main/system.erb", "application prompt")
        model = RecordingModel.new
        application = build_application(application_root, component_root, "ComponentPrompts::MainAgent", model:)

        application.call("message" => "hello")

        assert_equal "application prompt", model.requests.first.messages.first.text
      ensure
        remove_constant(:ComponentPrompts)
      end
    end
  end

  def test_component_prompt_is_used_when_application_has_no_override
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        write(application_root, "app/agents/component_fallback/main_agent.rb",
          "module ComponentFallback; class MainAgent < LittleGhost::Agent; end; end")
        write(component_root, "app/prompts/component_fallback/main/system.erb", "component prompt")
        model = RecordingModel.new
        application = build_application(application_root, component_root, "ComponentFallback::MainAgent", model:)

        application.call("message" => "hello")

        assert_equal "component prompt", model.requests.first.messages.first.text
      ensure
        remove_constant(:ComponentFallback)
      end
    end
  end

  def test_invocation_prompt_overrides_application_and_component_prompts
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        Dir.mktmpdir do |invocation_root|
          write(application_root, "app/agents/invocation_prompt/main_agent.rb",
            "module InvocationPrompt; class MainAgent < LittleGhost::Agent; end; end")
          write(application_root, "app/prompts/invocation_prompt/main/system.erb", "application prompt")
          write(component_root, "app/prompts/invocation_prompt/main/system.erb", "component prompt")
          write(invocation_root, "invocation_prompt/main/system.erb", "invocation prompt")
          model = RecordingModel.new
          application = build_application(application_root, component_root, "InvocationPrompt::MainAgent", model:)
          application.call(
            "message" => "hello",
            "template_paths" => [LittleGhost::Templates::TrustedPath.new(path: invocation_root)]
          )

          assert_equal "invocation prompt", model.requests.first.messages.first.text
        ensure
          remove_constant(:InvocationPrompt)
        end
      end
    end
  end

  def test_first_declared_component_prompt_wins
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |first_root|
        Dir.mktmpdir do |second_root|
          write(application_root, "app/agents/ordered_components/main_agent.rb",
            "module OrderedComponents; class MainAgent < LittleGhost::Agent; end; end")
          write(first_root, "app/prompts/ordered_components/main/system.erb", "first component")
          write(second_root, "app/prompts/ordered_components/main/system.erb", "second component")
          model = RecordingModel.new
          application = Class.new(LittleGhost::Application)
          application.root application_root
          application.agent "OrderedComponents::MainAgent"
          application.invocation Invocation
          application.models models_for(model)
          application.component LittleGhost::Component.new(root: first_root)
          application.component LittleGhost::Component.new(root: second_root)

          application.call("message" => "hello")

          assert_equal "first component", model.requests.first.messages.first.text
        ensure
          remove_constant(:OrderedComponents)
        end
      end
    end
  end

  def test_component_dsl_is_repeatable
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |first_root|
        Dir.mktmpdir do |second_root|
          write(application_root, "app/agents/repeatable_component/main_agent.rb",
            "module RepeatableComponent; class MainAgent < LittleGhost::Agent; system_prompt 'main'; end; end")
          write(first_root, "app/tools/repeatable_component/first_tool.rb",
            "module RepeatableComponent; class FirstTool < LittleGhost::Tool; end; end")
          write(second_root, "app/tools/repeatable_component/second_tool.rb",
            "module RepeatableComponent; class SecondTool < LittleGhost::Tool; end; end")
          application = Class.new(LittleGhost::Application)
          application.root application_root
          application.agent "RepeatableComponent::MainAgent"
          application.invocation Invocation
          application.models models_for(RecordingModel.new)
          application.component LittleGhost::Component.new(root: first_root)
          application.component LittleGhost::Component.new(root: second_root)

          instance = application.boot!

          assert_equal 2, instance.components.length
          assert RepeatableComponent.const_defined?(:FirstTool, false)
          assert RepeatableComponent.const_defined?(:SecondTool, false)
        ensure
          remove_constant(:RepeatableComponent)
        end
      end
    end
  end

  def test_duplicate_constant_mappings_fail_before_loading
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        write(application_root, "app/agents/duplicate_component_agent.rb",
          "class DuplicateComponentAgent < LittleGhost::Agent; end")
        write(component_root, "app/tools/duplicate_component_agent.rb",
          "class DuplicateComponentAgent < LittleGhost::Tool; end")
        application = build_application(application_root, component_root, "DuplicateComponentAgent")

        assert_raises(LittleGhost::Support::Loader::ConflictError) { application.boot! }
        refute Object.const_defined?(:DuplicateComponentAgent, false)
      end
    end
  end

  def test_same_component_cannot_own_a_constant_twice
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        write(application_root, "app/agents/repeated_owner_main_agent.rb",
          "class RepeatedOwnerMainAgent < LittleGhost::Agent; system_prompt 'main'; end")
        write(component_root, "app/tools/repeated_owner_tool.rb",
          "RepeatedOwnerFileLoaded = true; class RepeatedOwnerTool < LittleGhost::Tool; end")
        component = LittleGhost::Component.new(root: component_root)
        application = Class.new(LittleGhost::Application)
        application.root application_root
        application.agent "RepeatedOwnerMainAgent"
        application.invocation Invocation
        application.models models_for(RecordingModel.new)
        application.component component
        application.component component

        assert_raises(LittleGhost::Support::Loader::ConflictError) { application.boot! }
        refute Object.const_defined?(:RepeatedOwnerFileLoaded, false)
      end
    end
  end

  def test_namespace_constant_conflicts_fail_before_loading
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        write(application_root, "app/agents/namespace_collision.rb",
          "NamespaceCollisionLoaded = true; class NamespaceCollision < LittleGhost::Agent; end")
        write(component_root, "app/tools/namespace_collision/helper_tool.rb",
          "class NamespaceCollision::HelperTool < LittleGhost::Tool; end")
        application = build_application(application_root, component_root, "NamespaceCollision")

        assert_raises(LittleGhost::Support::Loader::ConflictError) { application.boot! }
        refute Object.const_defined?(:NamespaceCollisionLoaded, false)
      end
    end
  end

  def test_existing_constants_conflict_before_application_files_are_loaded
    Object.const_set(:ExistingComponentAgent, Class.new(LittleGhost::Agent))
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        write(application_root, "app/agents/existing_component_agent.rb",
          "ExistingComponentFileLoaded = true; class ExistingComponentAgent < LittleGhost::Agent; end")
        application = build_application(application_root, component_root, "ExistingComponentAgent")

        assert_raises(LittleGhost::Support::Loader::ConflictError) { application.boot! }
        refute Object.const_defined?(:ExistingComponentFileLoaded, false)
      end
    end
  ensure
    remove_constant(:ExistingComponentAgent)
  end

  def test_build_after_boot_accepts_constants_loaded_by_the_same_loader
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        write(application_root, "app/agents/build_after_boot_agent.rb",
          "class BuildAfterBootAgent < LittleGhost::Agent; system_prompt 'main'; end")
        application = build_application(application_root, component_root, "BuildAfterBootAgent")
        application.boot!

        isolated = application.build(models: models_for(RecordingModel.new))

        assert_equal BuildAfterBootAgent, isolated.instance_variable_get(:@agent_class)
      ensure
        remove_constant(:BuildAfterBootAgent)
      end
    end
  end

  def test_component_paths_cannot_escape_the_component_root
    Dir.mktmpdir do |component_root|
      Dir.mktmpdir do |outside|
        write(outside, "escaped_agent.rb", "class EscapedAgent; end")
        FileUtils.mkdir_p(File.join(component_root, "app"))
        File.symlink(outside, File.join(component_root, "app/agents"))

        component = LittleGhost::Component.new(root: component_root)
        assert_raises(LittleGhost::Support::Loader::ConflictError) { component.loader.registered_constants }
      end
    end

    Dir.mktmpdir do |component_root|
      Dir.mktmpdir do |outside|
        FileUtils.mkdir_p(File.join(component_root, "app"))
        File.symlink(outside, File.join(component_root, "app/prompts"))

        assert_raises(LittleGhost::Support::Loader::ConflictError) do
          LittleGhost::Component.new(root: component_root)
        end
      end
    end
  end

  def test_application_prompt_path_cannot_escape_the_application_root
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |component_root|
        Dir.mktmpdir do |outside|
          write(application_root, "app/agents/application_prompt_escape.rb",
            "class ApplicationPromptEscape < LittleGhost::Agent; end")
          FileUtils.mkdir_p(File.join(application_root, "app"))
          File.symlink(outside, File.join(application_root, "app/prompts"))
          application = build_application(application_root, component_root, "ApplicationPromptEscape")

          assert_raises(LittleGhost::Support::Loader::ConflictError) { application.boot! }
        end
      end
    end
  end

  def test_component_paths_are_revalidated_after_registration
    Dir.mktmpdir do |component_root|
      Dir.mktmpdir do |outside|
        write(component_root, "app/agents/replaced_component_agent.rb", "class ReplacedComponentAgent; end")
        write(component_root, "app/prompts/system.erb", "inside")
        write(outside, "replaced_component_agent.rb", "class ReplacedComponentAgent; end")
        write(outside, "system.erb", "outside")
        component = LittleGhost::Component.new(root: component_root)
        component.loader.registered_constants
        agents = File.join(component_root, "app/agents")
        prompts = File.join(component_root, "app/prompts")
        File.rename(agents, "#{agents}.original")
        File.rename(prompts, "#{prompts}.original")
        File.symlink(outside, agents)
        File.symlink(outside, prompts)

        assert_raises(LittleGhost::Support::Loader::ConflictError) { component.loader.eager_load }
        resolver = LittleGhost::Templates::Resolver.new(application_paths: component.prompt_paths)
        assert_raises(LittleGhost::Templates::InvalidTemplateError) { resolver.render("system") }
      ensure
        remove_constant(:ReplacedComponentAgent)
      end
    end
  end

  private

  def build_application(root, component_root, agent_name, model: RecordingModel.new)
    Class.new(LittleGhost::Application).tap do |application|
      application.root root
      application.agent agent_name
      application.invocation Invocation
      application.models models_for(model)
      application.component LittleGhost::Component.new(root: component_root)
    end
  end

  def models_for(model)
    LittleGhost::ModelRegistry.new
      .provider(:test) { |**| model }
      .profile("default", provider: :test, model: "test")
  end

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def remove_constant(name)
    Object.send(:remove_const, name) if Object.const_defined?(name, false)
  end
end
