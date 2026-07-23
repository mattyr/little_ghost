# frozen_string_literal: true

require "securerandom"

module LittleGhost
  module AGUI
    class Adapter
      TERMINAL_EVENTS = %i[run_partial run_cancel run_stop run_error].freeze

      def stream(events, thread_id:, run_id:)
        Enumerator.new do |output|
          message_id = nil
          message_started = false
          reasoning_id = nil
          reasoning_message_id = nil
          tool_call_ids = {}

          events.each do |source|
            if reasoning_id && source.type != :reasoning_delta
              output << event("REASONING_MESSAGE_END", messageId: reasoning_message_id)
              output << event("REASONING_END", messageId: reasoning_id)
              reasoning_id = nil
              reasoning_message_id = nil
            end
            if message_started && (TERMINAL_EVENTS.include?(source.type) || source.type == :model_retry)
              output << event("TEXT_MESSAGE_END", messageId: message_id)
              message_id = nil
              message_started = false
            end
            if message_started && source.type == :message_start
              output << event("TEXT_MESSAGE_END", messageId: message_id)
              message_id = nil
              message_started = false
            end

            case source.type
            when :run_start
              output << event("RUN_STARTED", threadId: thread_id, runId: run_id)
            when :message_start
              message_id = SecureRandom.uuid
            when :reasoning_delta
              if message_started
                output << event("TEXT_MESSAGE_END", messageId: message_id)
                message_id = nil
                message_started = false
              end
              unless reasoning_id
                reasoning_id = SecureRandom.uuid
                reasoning_message_id = SecureRandom.uuid
                output << event("REASONING_START", messageId: reasoning_id)
                output << event(
                  "REASONING_MESSAGE_START",
                  messageId: reasoning_message_id,
                  role: "reasoning"
                )
              end
              output << event(
                "REASONING_MESSAGE_CONTENT",
                messageId: reasoning_message_id,
                delta: source.data.fetch(:text)
              )
            when :text_delta
              message_id ||= SecureRandom.uuid
              unless message_started
                output << event("TEXT_MESSAGE_START", messageId: message_id, role: "assistant")
                message_started = true
              end
              output << event("TEXT_MESSAGE_CONTENT", messageId: message_id, delta: source.data.fetch(:text))
            when :message_stop
              if message_started
                output << event("TEXT_MESSAGE_END", messageId: message_id)
              end
              message_id = nil
              message_started = false
            when :tool_call_start
              tool_call_ids[source.data.fetch(:index)] = source.data.fetch(:id)
              output << event(
                "TOOL_CALL_START",
                toolCallId: source.data.fetch(:id),
                toolCallName: source.data.fetch(:name),
                parentMessageId: (message_id if message_started)
              )
            when :tool_call_delta
              output << event(
                "TOOL_CALL_ARGS",
                toolCallId: tool_call_ids.fetch(source.data.fetch(:index), source.data.fetch(:index).to_s),
                delta: source.data.fetch(:arguments)
              )
            when :tool_call_stop
              output << event("TOOL_CALL_END", toolCallId: source.data.fetch(:tool_use).id)
            when :tool_stop
              tool_use = source.data.fetch(:tool_use)
              result = source.data.fetch(:result)
              output << event(
                "TOOL_CALL_RESULT",
                messageId: SecureRandom.uuid,
                toolCallId: tool_use.id,
                content: result.content,
                status: result.status,
                role: "tool"
              )
            when :invocation_stop
              result = source.data.fetch(:result)
              output << custom(
                "little_ghost.usage",
                usage: result.usage.to_h,
                metadata: source.data.fetch(:metadata, {})
              )
            when :invocation_error
              output << custom(
                "little_ghost.usage",
                usage: source.data.fetch(:usage).to_h,
                metadata: source.data.fetch(:metadata, {})
              )
            when :model_retry
              tool_call_ids.clear
              output << custom("little_ghost.model_retry", source.data)
            when :subagent
              output << custom("little_ghost.subagent", source.data.fetch(:event, source.data))
            when :trace_context
              output << custom("little_ghost.trace_context", source.data.fetch(:context, source.data))
            when :run_partial
              output << custom(
                "little_ghost.run.partial",
                response: source.data.fetch(:response),
                message: source.data[:error]&.message
              )
              output << event(
                "RUN_FINISHED", threadId: thread_id, runId: run_id,
                result: {response: source.data.fetch(:response)}
              )
            when :run_cancel
              output << custom("little_ghost.run.canceled", reason: source.data[:error]&.message)
              output << event("RUN_FINISHED", threadId: thread_id, runId: run_id)
            when :run_stop
              output << event(
                "RUN_FINISHED", threadId: thread_id, runId: run_id,
                result: {response: source.data.fetch(:response)}
              )
            when :run_error
              output << event(
                "RUN_ERROR", threadId: thread_id, runId: run_id,
                message: source.data.fetch(:message),
                cleanupFailed: source.data.fetch(:cleanup_failed, true)
              )
            end
          end
        end
      end

      private

      def event(type, **attributes)
        {type:, **attributes.compact}
      end

      def custom(name, value = nil, **attributes)
        event("CUSTOM", name:, value: value || attributes)
      end
    end
  end
end
