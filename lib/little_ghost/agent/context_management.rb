# frozen_string_literal: true

require "json"
require "securerandom"

module LittleGhost
  class Agent
    module ContextManagement
      DEFAULT_CONTEXT_WINDOW_TOKENS = 200_000
      DEFAULT_COMPRESSION_THRESHOLD = 0.85
      DEFAULT_SUMMARY_RATIO = 0.3
      DEFAULT_PRESERVE_RECENT_MESSAGES = 10
      ESTIMATED_CHARS_PER_TOKEN = 4
      OUTPUT_LIMIT_STOP_REASONS = %i[max_tokens limit_output_tokens limit_total_tokens limit_turns].freeze
      SUMMARIZATION_PROMPT = <<~PROMPT
        You are a conversation summarizer. Provide a concise summary of the conversation history.

        Format requirements:
        - Create a structured, concise summary in bullet-point format.
        - Do not respond conversationally, address the user directly, or comment on tool availability.
        - Preserve key topics, questions, significant tool executions and results, code or technical information, and key insights.
        - Do not assume tool executions failed unless otherwise stated.
        - Write the summary in the third person.
      PROMPT

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def manage_context(
          context_window_tokens: DEFAULT_CONTEXT_WINDOW_TOKENS,
          compression_threshold: DEFAULT_COMPRESSION_THRESHOLD,
          summary_ratio: DEFAULT_SUMMARY_RATIO,
          preserve_recent_messages: DEFAULT_PRESERVE_RECENT_MESSAGES
        )
          context_window_tokens = Integer(context_window_tokens)
          compression_threshold = Float(compression_threshold)
          summary_ratio = Float(summary_ratio)
          preserve_recent_messages = Integer(preserve_recent_messages)
          raise ArgumentError, "context_window_tokens must be positive" unless context_window_tokens.positive?
          unless compression_threshold.positive? && compression_threshold <= 1
            raise ArgumentError, "compression_threshold must be between 0 and 1"
          end
          unless summary_ratio.between?(0.1, 0.8)
            raise ArgumentError, "summary_ratio must be between 0.1 and 0.8"
          end
          raise ArgumentError, "preserve_recent_messages must be at least 2" if preserve_recent_messages < 2

          @context_management_configuration = Support.immutable({
            context_window_tokens:,
            compression_threshold:,
            summary_ratio:,
            preserve_recent_messages:
          })
          before_model :compact_model_context
          after_model_error :compact_context_after_overflow
        end

        def context_management_configuration
          return @context_management_configuration if instance_variable_defined?(:@context_management_configuration)

          superclass.context_management_configuration if superclass.respond_to?(:context_management_configuration)
        end
      end

      private

      def compact_model_context(payload, context: nil)
        request = payload.fetch(:request)
        configuration = self.class.context_management_configuration
        limit = model_context_window_tokens(configuration)
        threshold = limit * configuration.fetch(:compression_threshold)
        return Support::Callbacks.continue if estimated_request_tokens(request) < threshold

        compacted = compact_context(request, configuration, context, context_window_tokens: limit)
        Support::Callbacks.replace(payload.merge(request: compacted))
      rescue CancelledError, DeadlineExceededError, CleanupError
        raise
      rescue => error
        context&.instrumentation&.emit(:context_compaction, outcome: :error, error_class: error.class.name)
        Support::Callbacks.continue
      end

      def compact_context_after_overflow(payload, context: nil)
        return Support::Callbacks.continue unless payload.fetch(:error).is_a?(ContextWindowOverflowError)

        configuration = self.class.context_management_configuration
        request = payload.fetch(:request)
        compacted = compact_context(
          request,
          configuration,
          context,
          context_window_tokens: model_context_window_tokens(configuration),
          reason: :overflow
        )
        Support::Callbacks.replace(payload.merge(request: compacted))
      end

      def summarize_oldest_messages(request, configuration, context)
        trusted, conversation = request.messages.partition { |message| %i[system developer].include?(message.role) }
        preserve = configuration.fetch(:preserve_recent_messages)
        split = [(conversation.length * configuration.fetch(:summary_ratio)).floor, 1].max
        split = [split, conversation.length - preserve].min
        raise ProtocolError, "Not enough conversation history to compact" unless split.positive?

        split = safe_summary_split(conversation, split)
        to_summarize = conversation.first(split)
        summary = generate_context_summary(to_summarize, request, context)
        ModelRequest.new(
          messages: [*trusted, summary, *conversation.drop(split)],
          tools: request.tools,
          settings: request.settings,
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        )
      end

      def compact_context(request, configuration, context, context_window_tokens:, reason: :threshold)
        compacted = summarize_oldest_messages(request, configuration, context)
        context&.instrumentation&.emit(
          :context_compaction,
          reason:,
          removed_messages: request.messages.length - compacted.messages.length,
          estimated_tokens: estimated_request_tokens(request),
          context_window_tokens:
        )
        compacted
      end

      def safe_summary_split(messages, split)
        while split < messages.length
          current = messages.fetch(split)
          previous = messages.fetch(split - 1)
          current_results = current.content.grep(Content::ToolResult).map(&:tool_use_id)
          previous_uses = previous.content.grep(Content::ToolUse).map(&:id)
          break if current_results.empty? && previous_uses.empty?

          split += 1
        end
        split
      end

      def generate_context_summary(messages, request, context)
        operation_id = SecureRandom.uuid
        started_at = monotonic_time
        instrument(
          :model_start,
          operation_id:,
          parent_operation_id: run&.operation_id,
          purpose: :context_compaction,
          **model_attributes
        )
        summary_request = ModelRequest.new(
          messages: [
            Message.new(role: :system, content: SUMMARIZATION_PROMPT),
            *messages,
            Message.new(role: :user, content: "Please summarize this conversation.")
          ],
          tools: [],
          settings: request.settings,
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        )
        response = nil
        time_to_first_token = nil
        model.stream(summary_request).each do |event|
          context&.check!
          time_to_first_token ||= duration_seconds(started_at) if model_output_event?(event)
          response = event.data[:response] if event.type == :message_stop
        end
        raise ProtocolError, "Context summarization ended without a response" unless response
        context&.record_usage(response.usage)
        if OUTPUT_LIMIT_STOP_REASONS.include?(response.stop_reason)
          raise OutputLimitError, "The context summary stopped before completion"
        end

        instrument(
          :model_stop,
          operation_id:,
          parent_operation_id: run&.operation_id,
          purpose: :context_compaction,
          outcome: :completed,
          duration_ms: duration_ms(started_at),
          time_to_first_token:,
          **model_attributes,
          **usage_attributes(response.usage)
        )
        Message.new(role: :user, content: response.message.content)
      rescue => error
        instrument(
          :model_stop,
          operation_id:,
          parent_operation_id: run&.operation_id,
          purpose: :context_compaction,
          outcome: :error,
          duration_ms: duration_ms(started_at),
          time_to_first_token:,
          error_class: error.class.name,
          **model_attributes
        )
        raise
      end

      def model_context_window_tokens(configuration)
        value = model.respond_to?(:metadata) && (
          model.metadata[:context_window_tokens] || model.metadata["context_window_tokens"] ||
          model.metadata[:context_window] || model.metadata["context_window"]
        )
        value = Integer(value) if value
        value&.positive? ? value : configuration.fetch(:context_window_tokens)
      rescue ArgumentError, TypeError
        configuration.fetch(:context_window_tokens)
      end

      def estimated_request_tokens(request)
        characters = JSON.generate(
          messages: request.messages.map(&:to_h),
          tools: request.tools
        ).length
        (characters.to_f / ESTIMATED_CHARS_PER_TOKEN).ceil
      rescue JSON::GeneratorError
        request.messages.sum { |message| message.text.length } / ESTIMATED_CHARS_PER_TOKEN
      end
    end
  end
end
