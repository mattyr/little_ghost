# frozen_string_literal: true

require "digest"
require "json"

module LittleGhost
  class Agent
    # Stop an agent from repeating a tool call that cannot make progress.
    # Detection follows identical tool names, arguments, result status, and result
    # content within one invocation.
    #
    #   class CustomerSupportAgent < LittleGhost::Agent
    #     detect_tool_loops warning_at: 3, terminate_at: 5,
    #       except: AccountRefreshTool
    #   end
    #
    # If a support model makes the same ineffective lookup three times, its third
    # result includes a warning to change approach. A fourth repeat carries the
    # final warning, and a fifth stops the run with ToolLoopError.
    #
    # Detection is inactive until +detect_tool_loops+ is declared. Exclusions may
    # be tool classes, instances, names, or symbols. State is isolated per active
    # invocation and guarded for concurrent tool batches; unfinished subagent
    # waits do not count as repeated progress failures.
    #
    # Only identical normalized arguments and results advance the counter. A
    # changed result resets that sequence, while a terminating repeat prevents
    # the duplicate tool body from running again.
    module ToolLoop
      WARNING = "Repeated tool call detected. Change the approach or arguments before calling this tool again." # :nodoc:
      FINAL_WARNING = "Final repeated tool call warning. Calling this tool again with identical arguments and result will stop the run." # :nodoc:
      TRACKED_INVOCATION_LIMIT = 1_000 # :nodoc:

      def self.included(base) # :nodoc:
        base.extend(ClassMethods)
        base.class_attribute :tool_loop_configuration_value
      end

      # Exposes tool-loop detection declarations on agent classes.
      # These methods become inheritable DSL entries when the capability is included.
      module ClassMethods
        # Enables repeated tool-call detection.
        #
        # +warning_at+ defaults to 3 identical calls and +terminate_at+ defaults
        # to 5. +except+ accepts tool classes, instances, names, or symbols.
        #
        # Raises ArgumentError unless +warning_at+ is at least 2 and
        # +terminate_at+ is greater than +warning_at+.
        def detect_tool_loops(warning_at: 3, terminate_at: 5, except: [])
          warning_at = Integer(warning_at)
          terminate_at = Integer(terminate_at)
          raise ArgumentError, "warning_at must be at least 2" if warning_at < 2
          raise ArgumentError, "terminate_at must be greater than warning_at" if terminate_at <= warning_at

          self.tool_loop_configuration_value = {
            warning_at:,
            terminate_at:,
            except: Array(except).map { |tool| tool_name(tool) }
          }
          after_initialize :initialize_tool_loop
          before_invocation :reset_tool_loop
          after_invocation :clear_tool_loop
          before_model :check_for_terminated_tool_loop
          before_tool :track_tool_call
          after_tool :detect_repeated_tool_call, prepend: true
        end

        def tool_loop_configuration = tool_loop_configuration_value # :nodoc:

        private

        def tool_name(tool)
          return tool.class.tool_name if tool.is_a?(LittleGhost::Tool)
          return tool.tool_name if tool.is_a?(Class) && tool <= LittleGhost::Tool

          tool.to_s
        end
      end

      private

      def reset_tool_loop(*, context: nil)
        @tool_loop_mutex.synchronize do
          if context
            remember_tool_loop_state(context, new_tool_loop_state)
          else
            @tool_loop_fallback = new_tool_loop_state
          end
        end
        Support::Callbacks.continue
      end

      def clear_tool_loop(*, context: nil)
        @tool_loop_mutex.synchronize do
          if context
            @tool_loop_runs.delete(context)
          else
            @tool_loop_fallback = new_tool_loop_state
          end
        end
        Support::Callbacks.continue
      end

      def check_for_terminated_tool_loop(*, context: nil)
        message = @tool_loop_mutex.synchronize { tool_loop_state(context)[:termination] }
        raise ToolLoopError, message if message

        Support::Callbacks.continue
      end

      def track_tool_call(payload, context: nil)
        tool_use = payload.fetch(:tool_use)
        return Support::Callbacks.continue if @tool_loop_except.include?(tool_use.name)

        key = [tool_use.name, tool_loop_digest(tool_use.input)]
        termination, newly_terminated = @tool_loop_mutex.synchronize do
          state = tool_loop_state(context)
          repeat = state[:repeats][key]
          newly_terminated = false
          if repeat && repeat[:count] >= @tool_loop_terminate_at - 1
            unless state[:termination]
              state[:termination] = "Stopped after detecting a repeated tool-call loop in #{tool_use.name.inspect}."
              newly_terminated = true
            end
          end
          unless state[:termination]
            advances = state[:inflight].values.none? { |call| call.fetch(:key) == key }
            state[:inflight][tool_use.id] = {key:, advances:}
          end
          [state[:termination], newly_terminated]
        end
        if termination
          if newly_terminated
            Instrumentation.publish(
              :tool_loop,
              operation_id: payload[:operation_id],
              parent_operation_id: payload[:parent_operation_id],
              action: :terminate,
              tool_name: tool_use.name
            )
          end
          Support::Callbacks.cancel(termination)
        else
          Support::Callbacks.continue
        end
      end

      def detect_repeated_tool_call(payload, context: nil)
        tool_use = payload.fetch(:tool_use)
        result = payload.fetch(:result)
        count = @tool_loop_mutex.synchronize do
          state = tool_loop_state(context)
          call = state[:inflight].delete(tool_use.id)
          next unless call&.fetch(:advances)
          next if unfinished_subagent_wait?(tool_use, result)

          result_digest = tool_loop_digest(status: result.status, content: result.content)
          key = call.fetch(:key)
          previous = state[:repeats][key]
          count = (previous && previous[:result] == result_digest) ? previous[:count] + 1 : 1
          state[:repeats][key] = {result: result_digest, count: count}
          count
        end
        return Support::Callbacks.continue unless count == @tool_loop_warning_at || count == @tool_loop_terminate_at - 1

        action = (count == @tool_loop_warning_at) ? :warn : :final_warning
        warning = (action == :warn) ? WARNING : FINAL_WARNING
        Instrumentation.publish(
          :tool_loop,
          operation_id: payload[:operation_id],
          parent_operation_id: payload[:parent_operation_id],
          action: action,
          tool_name: tool_use.name,
          count: count
        )
        replacement = Tool::ExecutionResult.new(
          content: "#{warning}\n\n#{result.content}",
          status: result.status,
          error: result.error
        )
        Support::Callbacks.replace(payload.merge(result: replacement))
      end

      def tool_loop_state(context)
        return @tool_loop_fallback unless context

        state = @tool_loop_runs[context] || new_tool_loop_state
        remember_tool_loop_state(context, state)
        state
      end

      def remember_tool_loop_state(context, state)
        @tool_loop_runs.delete(context)
        @tool_loop_runs[context] = state
        @tool_loop_runs.shift while @tool_loop_runs.length > TRACKED_INVOCATION_LIMIT
      end

      def initialize_tool_loop
        configuration = self.class.tool_loop_configuration
        @tool_loop_warning_at = configuration.fetch(:warning_at)
        @tool_loop_terminate_at = configuration.fetch(:terminate_at)
        @tool_loop_except = configuration.fetch(:except)
        @tool_loop_mutex = Mutex.new
        @tool_loop_runs = {}
        @tool_loop_fallback = new_tool_loop_state
      end

      def new_tool_loop_state
        {repeats: {}, inflight: {}, termination: nil}
      end

      def unfinished_subagent_wait?(tool_use, result)
        return false unless tool_use.name == "wait_for_subagents"

        JSON.parse(result.content.to_s)["status"] == "still_working"
      rescue JSON::ParserError, TypeError
        false
      end

      def tool_loop_digest(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical_tool_loop_value(value)))
      end

      def canonical_tool_loop_value(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            child = value.key?(key) ? value[key] : value[key.to_sym]
            [key, canonical_tool_loop_value(child)]
          end
        when Array
          value.map { |item| canonical_tool_loop_value(item) }
        else
          value
        end
      end
    end
  end
end
