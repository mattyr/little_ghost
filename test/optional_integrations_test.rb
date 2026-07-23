# frozen_string_literal: true

require "open3"
require "test_helper"

class OptionalIntegrationsTest < Minitest::Test
  def test_core_require_does_not_load_optional_integrations
    script = <<~RUBY
      require "little_ghost"
      abort if defined?(LittleGhost::AGUI)
      abort if defined?(LittleGhost::Hosting)
      abort if defined?(LittleGhost::SessionStores::AgentCoreMemory)
      abort if defined?(LittleGhost::Tools::Workspace)
      abort if defined?(LittleGhost::MCP)
      abort if defined?(LittleGhost::EventSink)
    RUBY

    _output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: __dir__ + "/..")

    assert status.success?
  end

  def test_integrations_have_explicit_entrypoints
    require "little_ghost/ag_ui"
    require "little_ghost/hosting"
    require "little_ghost/session_stores/agent_core_memory"
    require "little_ghost/tools"
    require "little_ghost/mcp"

    assert defined?(LittleGhost::AGUI::Adapter)
    assert defined?(LittleGhost::Hosting::AgentCoreRuntime)
    assert defined?(LittleGhost::SessionStores::AgentCoreMemory)
    assert defined?(LittleGhost::Tools::Workspace)
    assert defined?(LittleGhost::Tools::Shell)
    assert defined?(LittleGhost::MCP)
  end
end
