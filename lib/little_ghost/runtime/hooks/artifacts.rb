# frozen_string_literal: true

require "json"

module LittleGhost
  class Runtime
    module Hooks # :nodoc:
      # Implements the configured artifact lifecycle for input attachments and
      # Tool results. Public construction goes through Configuration#artifacts.
      class Artifacts < Hook # :nodoc:
        RESOURCE_KEY = Object.new.freeze
        MAX_BATCH_ARTIFACTS = 20
        MAX_BATCH_BYTES = LittleGhost::Artifacts::WorkspaceStore::DEFAULT_MAX_TOTAL_BYTES
        RESULT_THRESHOLD_TOKENS = 10_000
        RESULT_PREVIEW_TOKENS = 2_000

        InterjectionContext = Data.define(:run_context, :cancellation_token, :deadline) do
          def check!
            run_context.check!
            cancellation_token&.raise_if_cancelled!
            raise DeadlineExceededError, "The run deadline was reached" if deadline && Time.now >= deadline
          end

          def artifact_control_values
            {
              cancellation_tokens: [run_context.cancellation_token, cancellation_token].compact,
              deadlines: [run_context.deadline, deadline].compact
            }
          end
        end

        class << self
          attr_reader :resolver

          def configured(resolver: nil)
            Class.new(self).tap { |hook| hook.instance_variable_set(:@resolver, resolver) }
          end
        end

        def initialize
          @resolver = self.class.resolver
          @direct_stores = {}
          @direct_stores_mutex = Mutex.new
        end

        def prepare_execution(run)
          run.invocation.message = prepare_message(run, run.invocation.message, context: run.context)
          run
        end

        def prepare_interjection(run, payload)
          unless payload.is_a?(Hash)
            return prepare_message(run, payload, context: run.context)
          end

          key = payload.key?(:message) ? :message : "message"
          return payload unless payload.key?(key)

          context = interjection_context(run, payload)
          payload.merge(key => prepare_message(run, payload.fetch(key), context:))
        end

        def prepare_tool_result(result, tool_use:, run:, workspace:, context:)
          return result unless result.success?

          context&.check!
          explicit = result.artifacts
          oversized = oversized_result?(result)
          automatic = best_effort_oversized_artifact(result, tool_use:) if oversized
          return result if explicit.empty? && !oversized

          resolved, materializable = resolve_artifacts(explicit, run:, context:)
          enforce_batch_limits!(materializable)
          stored = materialize_batch(materializable, run:, workspace:, context:)
          descriptors = merge_descriptors(resolved, stored)
          automatic_descriptor = store_automatic(
            automatic,
            run:,
            workspace:,
            context:
          )
          return result if descriptors.empty? && !automatic_descriptor && !oversized

          all_descriptors = automatic_descriptor ? [*descriptors, automatic_descriptor] : descriptors
          presentations = presentation_content(
            resolved,
            descriptors
          )
          content = result_content(
            result,
            automatic: automatic_descriptor,
            oversized:
          )
          Tool::ExecutionResult.new(
            value: result.value,
            content:,
            status: result.status,
            error: result.error,
            artifacts: all_descriptors,
            presentation_content: [*result.presentation_content, *presentations]
          )
        rescue CancelledError, DeadlineExceededError, CleanupError
          raise
        rescue => error
          raise ToolError, "Tool artifacts could not be prepared (#{error.class})" unless explicit.empty?

          result
        end

        private

        def prepare_message(run, value, context:)
          context.check!
          message = normalize_message(value)
          attachments = message.content.filter_map.with_index(1) do |block, index|
            next unless block.is_a?(Content::Image) || block.is_a?(Content::Document)

            name = block.name
            name = "attachment-#{index}#{extension(block.media_type)}" if name.to_s.empty?
            Artifact.new(
              data: block.data,
              media_type: block.media_type,
              name:,
              metadata: {input_attachment: true}
            )
          end
          return value if attachments.empty?

          enforce_batch_limits!(attachments)
          descriptors = materialize_batch(
            attachments,
            run:,
            workspace: run.workspace,
            context:
          )
          attach_artifact_metadata(message, descriptors)
        rescue CancelledError, DeadlineExceededError, CleanupError
          raise
        rescue => error
          raise InvocationError, "Input artifacts could not be prepared (#{error.class})"
        end

        def resolve_artifacts(artifacts, run:, context:)
          context&.check!
          resolved = artifacts.map do |artifact|
            context&.check!
            next artifact unless artifact.deferred?
            next artifact unless @resolver

            value = @resolver.call(artifact, run:)
            context&.check!
            case value
            when nil
              artifact
            when String
              Artifact.new(
                data: value,
                media_type: artifact.media_type,
                name: artifact.name,
                metadata: artifact.metadata
              )
            when Artifact
              value
            else
              raise ToolError, "Artifact resolver must return bytes, an Artifact, or nil"
            end
          end.freeze
          context&.check!
          [resolved, resolved.select(&:inline?).freeze]
        end

        def store_automatic(artifact, run:, workspace:, context:)
          return unless artifact

          enforce_batch_limits!([artifact])
          materialize_batch([artifact], run:, workspace:, context:).fetch(0)
        rescue CancelledError, DeadlineExceededError, CleanupError
          raise
        rescue
          nil
        end

        def materialize_batch(artifacts, run:, workspace:, context:)
          return [].freeze if artifacts.empty?

          entries = artifacts.map do |artifact|
            {
              data: artifact.data,
              name: artifact.name,
              media_type: artifact.media_type,
              metadata: artifact.metadata
            }
          end
          store_for(run, workspace).write_batch(entries, context:)
        end

        def store_for(run, workspace)
          if run
            return run.shared_resource(RESOURCE_KEY) do
              LittleGhost::Artifacts::WorkspaceStore.new(workspace: run.workspace)
            end
          end

          key = workspace.object_id
          existing = @direct_stores_mutex.synchronize { @direct_stores[key] }
          return existing if existing

          store = LittleGhost::Artifacts::WorkspaceStore.new(workspace:)
          @direct_stores_mutex.synchronize { @direct_stores[key] ||= store }
        end

        def merge_descriptors(resolved, stored)
          stored_values = stored.each
          resolved.map do |artifact|
            artifact.inline? ? stored_values.next : artifact
          end.freeze
        end

        def presentation_content(artifacts, descriptors)
          artifacts.zip(descriptors).filter_map do |artifact, descriptor|
            next unless artifact.inline?

            content_class = artifact.media_type.start_with?("image/") ? Content::Image : Content::Document
            content_class.new(
              data: artifact.data,
              media_type: artifact.media_type,
              name: descriptor.name || "artifact"
            )
          end.freeze
        end

        def oversized_artifact(result, tool_use:)
          data, media_type, extension = serialized_value(result.value)
          Artifact.new(
            data:,
            media_type:,
            name: "#{tool_use.name}-#{tool_use.id}.#{extension}",
            metadata: {tool_name: tool_use.name, tool_call_id: tool_use.id, complete_result: true}
          )
        end

        def best_effort_oversized_artifact(result, tool_use:)
          oversized_artifact(result, tool_use:)
        rescue CancelledError, DeadlineExceededError, CleanupError
          raise
        rescue
          nil
        end

        def oversized_result?(result)
          Support::OutputTruncation.approx_token_count(result.content) > RESULT_THRESHOLD_TOKENS
        end

        def serialized_value(value)
          if value.is_a?(Hash) || value.is_a?(Array)
            [JSON.generate(value), "application/json", "json"]
          else
            [String(value), "text/plain", "txt"]
          end
        rescue JSON::GeneratorError, TypeError
          raise ToolError, "Tool value cannot be stored as an artifact"
        end

        def result_content(result, automatic:, oversized:)
          return result.content unless oversized

          preview = Support::OutputTruncation
            .truncate_middle_with_token_budget(result.content, RESULT_PREVIEW_TOKENS)
            .first
          return "Full result: #{artifact_label(automatic)}\n\nPreview:\n#{preview}" if automatic

          "Full result exceeded artifact storage limits.\n\nPreview:\n#{preview}"
        end

        def artifact_label(artifact)
          details = [artifact.media_type, artifact.bytes && "#{artifact.bytes} bytes"].compact.join(", ")
          details.empty? ? artifact.reference : "#{artifact.reference} (#{details})"
        end

        def attach_artifact_metadata(message, artifacts)
          metadata = message.metadata.to_h.merge(
            "little_ghost_artifacts" => artifacts.map do |artifact|
              {
                "reference" => artifact.reference,
                "name" => artifact.name,
                "media_type" => artifact.media_type,
                "bytes" => artifact.bytes
              }.compact
            end
          )
          Message.new(
            role: message.role,
            content: message.content,
            metadata:
          )
        end

        def normalize_message(value)
          return value if value.is_a?(Message)
          return Message.coerce(value) if value.is_a?(Hash)

          Message.new(role: :user, content: value)
        end

        def interjection_context(run, payload)
          token = payload[:cancellation_token] || payload["cancellation_token"]
          deadline = payload[:deadline] || payload["deadline"]
          return run.context unless token || deadline

          InterjectionContext.new(run_context: run.context, cancellation_token: token, deadline:)
        end

        def enforce_batch_limits!(artifacts)
          raise ToolError, "Artifact batch exceeds the #{MAX_BATCH_ARTIFACTS}-item limit" if artifacts.length > MAX_BATCH_ARTIFACTS
          maximum = LittleGhost::Artifacts::WorkspaceStore::DEFAULT_MAX_ARTIFACT_BYTES
          if artifacts.any? { |artifact| artifact.data.bytesize > maximum }
            raise ToolError, "Artifact exceeds the #{maximum}-byte limit"
          end
          if artifacts.sum { |artifact| artifact.data.bytesize } > MAX_BATCH_BYTES
            raise ToolError, "Artifact batch exceeds the #{MAX_BATCH_BYTES}-byte limit"
          end
        end

        def extension(media_type)
          {
            "image/png" => ".png",
            "image/jpeg" => ".jpg",
            "image/gif" => ".gif",
            "image/webp" => ".webp",
            "application/pdf" => ".pdf",
            "text/plain" => ".txt",
            "text/markdown" => ".md"
          }.fetch(media_type.to_s, "")
        end
      end
    end
  end
end
