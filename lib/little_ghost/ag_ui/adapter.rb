# frozen_string_literal: true

require "securerandom"

module LittleGhost
  module AGUI
    class Adapter
      TERMINAL_EVENTS = %i[run_partial run_cancel run_stop run_error].freeze

      def stream(events, thread_id:, run_id:)
        Enumerator.new do |output|
          message_id = nil
          tool_call_ids = {}

          events.each do |source|
            next if private_event?(source)

            if message_id && (TERMINAL_EVENTS.include?(source.type) || source.type == :model_retry)
              output << event("TEXT_MESSAGE_END", messageId: message_id)
              message_id = nil
            end
            if message_id && source.type == :message_start
              output << event("TEXT_MESSAGE_END", messageId: message_id)
              message_id = nil
            end

            case source.type
            when :run_start
              output << event("RUN_STARTED", threadId: thread_id, runId: run_id)
            when :message_start
              message_id = SecureRandom.uuid
              output << event("TEXT_MESSAGE_START", messageId: message_id, role: "assistant")
            when :text_delta
              unless message_id
                message_id = SecureRandom.uuid
                output << event("TEXT_MESSAGE_START", messageId: message_id, role: "assistant")
              end
              output << event("TEXT_MESSAGE_CONTENT", messageId: message_id, delta: source.data.fetch(:text))
            when :message_stop
              if message_id
                output << event("TEXT_MESSAGE_END", messageId: message_id)
                message_id = nil
              end
            when :tool_call_start
              tool_call_ids[source.data.fetch(:index)] = source.data.fetch(:id)
              output << event(
                "TOOL_CALL_START",
                toolCallId: source.data.fetch(:id),
                toolCallName: source.data.fetch(:name),
                parentMessageId: message_id
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

      def private_event?(source)
        source.type.to_s.start_with?("reasoning")
      end

      def event(type, **attributes)
        {type:, **attributes.compact}
      end

      def custom(name, value = nil, **attributes)
        event("CUSTOM", name:, value: value || attributes)
      end
    end
  end
end
