# frozen_string_literal: true

require_relative "little_ghost/version"
require_relative "little_ghost/errors"
require_relative "little_ghost/tracing/open_telemetry"
require_relative "little_ghost/support"
require_relative "little_ghost/invocation"
require_relative "little_ghost/lookup"
require_relative "little_ghost/usage"
require_relative "little_ghost/content"
require_relative "little_ghost/message"
require_relative "little_ghost/stream_event"
require_relative "little_ghost/model_request"
require_relative "little_ghost/model_response"
require_relative "little_ghost/run_result"
require_relative "little_ghost/model_capabilities"
require_relative "little_ghost/model"
require_relative "little_ghost/model_registry"
require_relative "little_ghost/providers/sse_parser"
require_relative "little_ghost/providers/http_transport"
require_relative "little_ghost/providers/openai_compatible"
require_relative "little_ghost/providers/openai"
require_relative "little_ghost/providers/open_router"
require_relative "little_ghost/providers/bedrock"
require_relative "little_ghost/run_context"
require_relative "little_ghost/workspace"
require_relative "little_ghost/sandbox"
require_relative "little_ghost/tool"
require_relative "little_ghost/tool_registry"
require_relative "little_ghost/structured_output"
require_relative "little_ghost/prompt_resolver"
require_relative "little_ghost/session_store"
require_relative "little_ghost/session_stores/memory"
require_relative "little_ghost/session"
require_relative "little_ghost/skills"
require_relative "little_ghost/tools/write_todos"
require_relative "little_ghost/run"
require_relative "little_ghost/subagents/definition"
require_relative "little_ghost/subagents/agent_path"
require_relative "little_ghost/subagents/manager"
require_relative "little_ghost/agent_interruptions"
require_relative "little_ghost/agent"
require_relative "little_ghost/agent_builder"
require_relative "little_ghost/workflow"
require_relative "little_ghost/runtime"

module LittleGhost
  class << self
    def configuration
      Thread.current[:little_ghost_configuration] || (@configuration ||= Configuration.new)
    end

    alias_method :default_configuration, :configuration

    def configure(&block)
      configuration.configure(&block)
    end

    def with_configuration(configuration)
      previous = Thread.current[:little_ghost_configuration]
      Thread.current[:little_ghost_configuration] = configuration
      yield
    ensure
      Thread.current[:little_ghost_configuration] = previous
    end
  end
end
