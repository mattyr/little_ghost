# frozen_string_literal: true

require "securerandom"

module LittleGhost
  class Agent
    module ToolResultOffloading
      DEFAULT_MAX_CHARS = 6_000
      DEFAULT_PREVIEW_CHARS = 3_000
      DEFAULT_SUBAGENT_INLINE_TOKENS = 8_000
      DEFAULT_MAX_STORED_ITEMS = 64
      DEFAULT_MAX_STORED_BYTES = 32 * 1024 * 1024
      DEFAULT_MAX_ENTRY_BYTES = 10 * 1024 * 1024
      DEFAULT_RETRIEVAL_CONTEXT_LINES = 5
      MAX_RETRIEVAL_CONTEXT_LINES = 100
      MAX_RETRIEVAL_PATTERN_CHARS = 200
      RETRIEVAL_REGEXP_TIMEOUT = 0.1
      ESTIMATED_CHARS_PER_TOKEN = 4
      DEFAULT_EXCLUDED_TOOLS = %w[skills retrieve_offloaded_content].freeze
      SUBAGENT_RESULT_TOOLS = %w[spawn_subagent send_message_to_subagent wait_for_subagents].freeze

      class Store
        def initialize(max_items:, max_bytes:, max_entry_bytes:)
          @values = {}
          @bytes = 0
          @max_items = max_items
          @max_bytes = max_bytes
          @max_entry_bytes = max_entry_bytes
          @mutex = Mutex.new
        end

        def write(content)
          value = String(content)
          bytes = value.bytesize
          return if bytes > @max_entry_bytes

          @mutex.synchronize do
            return if @values.length >= @max_items || @bytes + bytes > @max_bytes

            retained = value.frozen? ? value : value.dup.freeze
            bytes = retained.bytesize
            return if bytes > @max_entry_bytes || @bytes + bytes > @max_bytes

            reference = SecureRandom.uuid
            @values[reference] = retained
            @bytes += bytes
            reference
          end
        end

        def read(reference)
          @mutex.synchronize { @values.fetch(reference.to_s) }
        rescue KeyError
          raise ToolError, "Unknown offloaded content reference"
        end
      end

      class RetrievalTool < Tool
        tool_name "retrieve_offloaded_content"
        description <<~DESCRIPTION.strip
          Retrieve content removed from active model context. Prefer pattern or line_range for large values;
          results include 1-indexed line numbers and are bounded. Omit selectors only when the full value is needed.
        DESCRIPTION
        input_schema(
          type: "object",
          properties: {
            reference: {type: "string"},
            pattern: {type: "string", maxLength: MAX_RETRIEVAL_PATTERN_CHARS},
            line_range: {
              type: "object",
              properties: {
                start: {type: "integer", minimum: 1},
                end: {type: "integer", minimum: 1}
              },
              required: %w[start end],
              additionalProperties: false
            },
            context_lines: {type: "integer", minimum: 0, maximum: MAX_RETRIEVAL_CONTEXT_LINES}
          },
          required: ["reference"],
          additionalProperties: false
        )

        def initialize(reader:, run: nil)
          super(run:)
          @reader = reader
        end

        def call(input, context:)
          options = {}
          %w[pattern line_range context_lines].each do |name|
            options[name.to_sym] = input[name] if input.key?(name)
          end
          @reader.call(input.fetch("reference"), **options)
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def offload_large_tool_results(max_chars: DEFAULT_MAX_CHARS, preview_chars: DEFAULT_PREVIEW_CHARS,
          subagent_inline_tokens: DEFAULT_SUBAGENT_INLINE_TOKENS,
          max_stored_items: DEFAULT_MAX_STORED_ITEMS,
          max_stored_bytes: DEFAULT_MAX_STORED_BYTES,
          max_entry_bytes: DEFAULT_MAX_ENTRY_BYTES,
          excluded_tools: DEFAULT_EXCLUDED_TOOLS)
          max_chars = Integer(max_chars)
          preview_chars = Integer(preview_chars)
          subagent_inline_tokens = Integer(subagent_inline_tokens)
          max_stored_items = Integer(max_stored_items)
          max_stored_bytes = Integer(max_stored_bytes)
          max_entry_bytes = Integer(max_entry_bytes)
          raise ArgumentError, "max_chars must be positive" unless max_chars.positive?
          raise ArgumentError, "preview_chars cannot be negative" if preview_chars.negative?
          raise ArgumentError, "subagent_inline_tokens must be positive" unless subagent_inline_tokens.positive?
          raise ArgumentError, "max_stored_items must be positive" unless max_stored_items.positive?
          raise ArgumentError, "max_stored_bytes must be positive" unless max_stored_bytes.positive?
          raise ArgumentError, "max_entry_bytes must be positive" unless max_entry_bytes.positive?
          if max_entry_bytes > max_stored_bytes
            raise ArgumentError, "max_entry_bytes cannot exceed max_stored_bytes"
          end

          @tool_result_offloading_configuration = {
            max_chars:,
            preview_chars:,
            subagent_inline_tokens:,
            max_stored_items:,
            max_stored_bytes:,
            max_entry_bytes:,
            excluded_tools: excluded_tools.map { |tool| tool.to_s.dup.freeze }.freeze
          }.freeze
          tools { RetrievalTool.new(reader: method(:retrieve_offloaded_content), run:) }
          after_initialize :initialize_tool_result_offloading
          before_model :reset_subagent_inline_budget
          after_tool :offload_large_tool_result
        end

        def tool_result_offloading_configuration
          return @tool_result_offloading_configuration if instance_variable_defined?(:@tool_result_offloading_configuration)

          superclass.tool_result_offloading_configuration if superclass.respond_to?(:tool_result_offloading_configuration)
        end
      end

      private

      def initialize_tool_result_offloading
        configuration = self.class.tool_result_offloading_configuration
        @tool_result_store = Store.new(
          max_items: configuration.fetch(:max_stored_items),
          max_bytes: configuration.fetch(:max_stored_bytes),
          max_entry_bytes: configuration.fetch(:max_entry_bytes)
        )
        @subagent_budget_mutex = Mutex.new
        @subagent_inline_budgets = ObjectSpace::WeakMap.new
        @subagent_inline_fallback = 0
      end

      def retrieve_offloaded_content(reference, pattern: nil, line_range: nil, context_lines: nil)
        content = @tool_result_store.read(reference)
        return content if pattern.nil? && line_range.nil? && context_lines.nil?

        search_offloaded_content(
          content,
          pattern:,
          line_range:,
          context_lines: context_lines.nil? ? DEFAULT_RETRIEVAL_CONTEXT_LINES : context_lines,
          max_chars: self.class.tool_result_offloading_configuration.fetch(:max_chars)
        )
      end

      def search_offloaded_content(content, pattern:, line_range:, context_lines:, max_chars:)
        lines = content.split("\n", -1)
        return "Content is empty (0 lines)." if lines == [""]

        context_lines = Integer(context_lines)
        unless context_lines.between?(0, MAX_RETRIEVAL_CONTEXT_LINES)
          raise ToolError, "context_lines must be between 0 and #{MAX_RETRIEVAL_CONTEXT_LINES}"
        end

        first, last = retrieval_scope(line_range, lines.length)
        return first if first.is_a?(String)

        if pattern && !pattern.empty?
          search_offloaded_lines(lines, pattern, first, last, context_lines, max_chars, line_range)
        else
          last = [first + [context_lines, 1].max - 1, last].min if line_range.nil?
          format_offloaded_range(lines, first, last, max_chars)
        end
      rescue ArgumentError, TypeError
        raise ToolError, "Offloaded content selectors are invalid"
      rescue Regexp::TimeoutError
        raise ToolError, "Offloaded content search timed out; use a simpler pattern"
      end

      def retrieval_scope(line_range, total_lines)
        return [0, total_lines - 1] if line_range.nil?
        raise ToolError, "line_range must be an object" unless line_range.is_a?(Hash)

        values = line_range.transform_keys(&:to_s)
        start_line = Integer(values.fetch("start"))
        end_line = Integer(values.fetch("end"))
        return ["Error: line_range.start (#{start_line}) must be >= 1.", nil] if start_line < 1
        if start_line > end_line
          return ["Error: line_range.start (#{start_line}) must be <= line_range.end (#{end_line}).", nil]
        end
        if start_line > total_lines
          return ["Error: line_range.start (#{start_line}) is beyond content length (#{total_lines} lines).", nil]
        end

        [start_line - 1, [end_line - 1, total_lines - 1].min]
      rescue KeyError
        raise ToolError, "line_range requires start and end"
      end

      def search_offloaded_lines(lines, pattern, first, last, context_lines, max_chars, line_range)
        original_pattern = pattern.to_s
        candidate = original_pattern[0, MAX_RETRIEVAL_PATTERN_CHARS]
        expression = offloaded_pattern(candidate)
        matches = (first..last).select { |index| expression.match?(lines[index]) }
        scope = line_range ? " in lines #{first + 1}-#{last + 1}" : ""
        if matches.empty?
          return "No matches found for pattern '#{safe_pattern_label(original_pattern)}'#{scope} " \
            "(searched #{last - first + 1} lines)."
        end

        visible = matches.each_with_object({}) do |match, indexes|
          ([first, match - context_lines].max..[last, match + context_lines].min).each { |index| indexes[index] = true }
        end.keys.sort
        label = safe_pattern_label(original_pattern)
        header = "[#{matches.length} match#{"es" unless matches.one?} for /#{label}/#{scope}]"
        body = format_offloaded_lines(lines, visible, matches.to_h { |index| [index, true] })
        "#{header}\n\n#{truncate_offloaded_content(body, max_chars, "output truncated, narrow your search")}"
      end

      def format_offloaded_range(lines, first, last, max_chars)
        header = "[Lines #{first + 1}-#{last + 1} of #{lines.length}]"
        body = format_offloaded_lines(lines, (first..last).to_a, {})
        "#{header}\n\n#{truncate_offloaded_content(body, max_chars, "output truncated, narrow your range")}"
      end

      def offloaded_pattern(pattern)
        Regexp.new(pattern, timeout: RETRIEVAL_REGEXP_TIMEOUT)
      rescue RegexpError
        Regexp.new(Regexp.escape(pattern), timeout: RETRIEVAL_REGEXP_TIMEOUT)
      end

      def format_offloaded_lines(lines, indexes, matches)
        width = (indexes.last.to_i + 1).to_s.length
        previous = nil
        indexes.flat_map do |index|
          separator = (previous && index > previous + 1) ? ["---"] : []
          previous = index
          prefix = matches[index] ? ">" : " "
          separator << "#{prefix} #{(index + 1).to_s.rjust(width)}| #{lines[index]}"
        end.join("\n")
      end

      def truncate_offloaded_content(content, max_chars, message)
        return content if content.length <= max_chars

        boundary = content.rindex("\n", max_chars)
        boundary = max_chars unless boundary&.positive?
        "#{content[0, boundary]}\n\n[#{message}]"
      end

      def safe_pattern_label(pattern)
        pattern.gsub(/[\n\r\/\]]/, " ")[0, 50]
      end

      def reset_subagent_inline_budget(*, context: nil)
        @subagent_budget_mutex.synchronize do
          if context
            @subagent_inline_budgets[context] = 0
          else
            @subagent_inline_fallback = 0
          end
        end
        Support::Callbacks.continue
      end

      def offload_large_tool_result(payload, context: nil)
        configuration = self.class.tool_result_offloading_configuration
        tool_use = payload.fetch(:tool_use)
        result = payload.fetch(:result)
        return Support::Callbacks.continue if configuration.fetch(:excluded_tools).include?(tool_use.name)
        if SUBAGENT_RESULT_TOOLS.include?(tool_use.name)
          return Support::Callbacks.continue if reserve_subagent_inline_budget(result.content, context, configuration)

          return offload_tool_result(payload, preview_chars: 0, subagent_overflow: true)
        end
        return Support::Callbacks.continue if result.content.length <= configuration.fetch(:max_chars)

        offload_tool_result(payload, preview_chars: configuration.fetch(:preview_chars))
      end

      def offload_tool_result(payload, preview_chars:, subagent_overflow: false)
        result = payload.fetch(:result)
        reference = @tool_result_store.write(result.content)
        preview = result.content[0, preview_chars]
        return omitted_tool_result(payload, preview:, subagent_overflow:) unless reference

        explanation = if subagent_overflow
          "Subagent result exceeded the shared inline budget. Use retrieve_offloaded_content only if the result is needed."
        end
        parts = [preserved_tool_loop_warning(result.content), "[Offloaded: #{reference}]", explanation]
        parts << preview unless preview.empty?
        parts << "[Stored reference: #{reference}]"
        replacement = Tool::ExecutionResult.new(
          content: parts.compact.join("\n\n"),
          status: result.status,
          error: result.error
        )
        Support::Callbacks.replace(payload.merge(result: replacement))
      rescue
        raise unless subagent_overflow

        omitted_tool_result(payload, preview: "", subagent_overflow: true)
      end

      def omitted_tool_result(payload, preview:, subagent_overflow:)
        result = payload.fetch(:result)
        warning = preserved_tool_loop_warning(result.content)
        message = if subagent_overflow
          "Subagent result exceeded the shared inline budget but could not be retained within the offload storage budget. " \
            "Raw content was omitted; rerun the subagent if the result is still needed."
        else
          "Full tool result could not be retained within the offload storage budget. " \
            "The preview below is the only retained content."
        end
        replacement = Tool::ExecutionResult.new(
          content: [warning, message, preview.empty? ? nil : preview].compact.join("\n\n"),
          status: result.status,
          error: result.error
        )
        Support::Callbacks.replace(payload.merge(result: replacement))
      end

      def reserve_subagent_inline_budget(content, context, configuration)
        tokens = [(content.to_s.length.to_f / ESTIMATED_CHARS_PER_TOKEN).ceil, 1].max
        limit = configuration.fetch(:subagent_inline_tokens)
        @subagent_budget_mutex.synchronize do
          used = context ? (@subagent_inline_budgets[context] || 0) : @subagent_inline_fallback
          return false if used + tokens > limit

          if context
            @subagent_inline_budgets[context] = used + tokens
          else
            @subagent_inline_fallback = used + tokens
          end
        end
        true
      end

      def preserved_tool_loop_warning(content)
        return unless defined?(ToolLoop)

        [ToolLoop::WARNING, ToolLoop::FINAL_WARNING].find do |warning|
          content.to_s.start_with?(warning)
        end
      end
    end
  end
end
