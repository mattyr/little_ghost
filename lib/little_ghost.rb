# frozen_string_literal: true

require_relative "little_ghost/version"
require_relative "little_ghost/errors"
require_relative "little_ghost/execution_state"
require_relative "little_ghost/support"
require_relative "little_ghost/data_map"
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
require_relative "little_ghost/agent_stream_source"
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
require_relative "little_ghost/sandbox/process_session"
require_relative "little_ghost/sandboxes/unrestricted"
require_relative "little_ghost/sandboxes/bubblewrap"
require_relative "little_ghost/sandboxes/seatbelt"
require_relative "little_ghost/sandboxes/native"
require_relative "little_ghost/tool"
require_relative "little_ghost/tool_execution"
require_relative "little_ghost/tool_registry"
require_relative "little_ghost/code_mode"
require_relative "little_ghost/code_mode/ruby_engine"
require_relative "little_ghost/code_mode/runtime"
require_relative "little_ghost/structured_output"
require_relative "little_ghost/prompt_resolver"
require_relative "little_ghost/session_store"
require_relative "little_ghost/session_stores/memory"
require_relative "little_ghost/session_stores/filesystem"
require_relative "little_ghost/session"
require_relative "little_ghost/skills"
require_relative "little_ghost/tools/write_todos"
require_relative "little_ghost/run"
require_relative "little_ghost/execution"
require_relative "little_ghost/subagents/definition"
require_relative "little_ghost/subagents/agent_path"
require_relative "little_ghost/subagents/manager"
require_relative "little_ghost/agent_interjections"
require_relative "little_ghost/assembly"
require_relative "little_ghost/assembly_execution"
require_relative "little_ghost/agent"
require_relative "little_ghost/workflow"
require_relative "little_ghost/swarm"
require_relative "little_ghost/graph"
require_relative "little_ghost/assembly_builder"
require_relative "little_ghost/agent_factory"
require_relative "little_ghost/runtime/hook"
require_relative "little_ghost/runtime"

# Build AI features as ordinary Ruby classes. An Agent owns one model
# conversation. Larger units called Assemblies coordinate several Agents while
# keeping the same +ask+ and +stream_ask+ entrypoints.
#
# Start with one model-driven behavior:
#
#   class CustomerSupportAgent < LittleGhost::Agent
#     description "Handles support requests"
#     model "openrouter:openai/gpt-5.6-luna"
#     system_prompt "Answer customer questions clearly."
#   end
#
#   run = CustomerSupportAgent.ask("Why is transfer 481 still pending?")
#   run.completed? # => true
#   run.response
#   # One possible response: Transfer 481 is waiting for the receiving bank.
#
# The class holds reusable behavior. Each call creates a Run, which records the
# result and closes the resources opened for that request. Workflow, Swarm, and
# Graph are Assembly types for coordinating more than one participant.
#
# Configure LittleGhost before the first call. The first standalone call builds
# a shared Runtime from that configuration. +with_configuration+ can select an
# independent configuration for one execution context.
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
    # make application-level changes before invoking an agent. Once the shared
    # Runtime is ready, later mutations raise ConfigurationError.
    def configure(&block)
      configuration.configure(&block)
    end

    # Returns the shared Runtime for the active Configuration.
    #
    # Most applications do not need to call this method. Standalone Agent and
    # Assembly entrypoints use it automatically. Runtime construction is lazy,
    # thread-safe, and locks the active Configuration after it succeeds.
    def runtime = configuration.runtime

    # Returns the model resolver owned by the active process configuration.
    def model_resolver = configuration.model_resolver

    # Makes +configuration+ and its independent shared Runtime current only
    # while the block runs.
    #
    # Execution state restores the previous configuration even when the block
    # raises. Other execution contexts continue to see their own configuration.
    def with_configuration(configuration)
      ExecutionState.with(configuration:) { yield }
    end
  end
end
