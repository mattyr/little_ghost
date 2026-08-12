# frozen_string_literal: true

require_relative "little_ghost/version"
require_relative "little_ghost/errors"
require_relative "little_ghost/execution_state"
require_relative "little_ghost/support"
require_relative "little_ghost/events"
require_relative "little_ghost/instrumentation"
require_relative "little_ghost/tracing/open_telemetry"
require_relative "little_ghost/invocation"
require_relative "little_ghost/lookup"
require_relative "little_ghost/path_set"
require_relative "little_ghost/usage"
require_relative "little_ghost/content"
require_relative "little_ghost/message"
require_relative "little_ghost/stream_event"
require_relative "little_ghost/model_request"
require_relative "little_ghost/model_response"
require_relative "little_ghost/run_result"
require_relative "little_ghost/model_capabilities"
require_relative "little_ghost/models/target"
require_relative "little_ghost/models/details"
require_relative "little_ghost/model"
require_relative "little_ghost/support/sse_parser"
require_relative "little_ghost/support/http_client"
require_relative "little_ghost/providers/base"
require_relative "little_ghost/providers/configuration"
require_relative "little_ghost/models/catalog/source"
require_relative "little_ghost/models/catalog/models_dev_source"
require_relative "little_ghost/providers/openai_compatible"
require_relative "little_ghost/providers/openai"
require_relative "little_ghost/providers/open_router"
require_relative "little_ghost/providers/bedrock"
require_relative "little_ghost/providers/anthropic"
require_relative "little_ghost/providers/gemini"
require_relative "little_ghost/providers/vertex_ai"
require_relative "little_ghost/models/catalog"
require_relative "little_ghost/models/catalog_snapshot"
require_relative "little_ghost/models/configuration"
require_relative "little_ghost/provider_registry"
require_relative "little_ghost/model_resolver"
require_relative "little_ghost/run_context"
require_relative "little_ghost/workspace"
require_relative "little_ghost/sandbox"
require_relative "little_ghost/unrestricted_sandbox"
require_relative "little_ghost/tool"
require_relative "little_ghost/tool_execution"
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
require_relative "little_ghost/runtime/hook"
require_relative "little_ghost/runtime"

# Build AI features with reusable agents and agentic workflows. LittleGhost can
# sit inside an existing Ruby system or support a dedicated AI service, keeping
# models, prompts, tools, sessions, streaming, and instrumentation behind a
# cohesive set of Ruby conventions.
#
# A customer support agent can answer directly, use an application tool, or ask a
# specialist for research while the caller observes one run:
#
#   LittleGhost.configure do |config|
#     config.providers = {
#       openai: {adapter: :openai, api_key: ENV.fetch("OPENAI_API_KEY")}
#     }
#     config.models = {
#       customer_support: {target: "openai:gpt-5.6-luna"}
#     }
#     config.default_model = :customer_support
#   end
#
#   class ResearchAgent < LittleGhost::Agent
#     description "Researches difficult support questions"
#     model "customer_support.research"
#   end
#
#   class CustomerSupportAgent < LittleGhost::Agent
#     description "Handles support requests"
#     model :customer_support
#     tools AccountTool
#     subagent ResearchAgent, kind: "research"
#   end
#
#   run = CustomerSupportAgent.ask("Why is transfer 481 still pending?")
#   run.completed? # => true
#   run.response   # => "Transfer 481 is waiting for the receiving bank."
#
# Agent subclasses hold reusable behavior; Invocation objects carry one request,
# and Run objects own execution and cleanup. Workflow subclasses can compose
# several agents when ordinary Ruby branching is clearer than one agent loop.
#
# LittleGhost.configuration is process-wide unless LittleGhost.with_configuration
# supplies an execution-scoped replacement. Configuration is loaded lazily and
# snapshotted into a Runtime, so make application changes before the first agent
# runtime is built.
module LittleGhost
  class << self
    # The configuration active in the current execution context, falling back to
    # the process-wide default.
    def configuration
      ExecutionState[:configuration] || (@configuration ||= Configuration.new)
    end

    # Opens the active Configuration for application setup and returns it.
    #
    # Configuration files are loaded lazily when a runtime is first built, so
    # make application-level changes before invoking an agent.
    def configure(&block)
      configuration.configure(&block)
    end

    # Returns the model resolver owned by the active process configuration.
    def model_resolver = configuration.model_resolver

    # Makes +configuration+ current only while the block runs.
    #
    # Execution state restores the previous configuration even when the block
    # raises. Other execution contexts continue to see their own configuration.
    def with_configuration(configuration)
      ExecutionState.with(configuration:) { yield }
    end
  end
end
