# frozen_string_literal: true

module LittleGhost
  module Support
    # OutputTruncation keeps large tool results within a predictable context
    # budget without breaking UTF-8. Its byte-to-token estimate is deliberately
    # approximate; use a provider tokenizer when exact accounting is required.
    module OutputTruncation
      # Byte estimate used when no provider tokenizer is available.
      APPROX_BYTES_PER_TOKEN = 4

      module_function

      # Estimates tokens from the UTF-8 byte length of +text+.
      def approx_token_count(text)
        approx_tokens_from_byte_count(String(text).bytesize)
      end

      # Converts a token budget to its approximate byte budget.
      def approx_bytes_for_tokens(tokens)
        Integer(tokens) * APPROX_BYTES_PER_TOKEN
      end

      # Converts bytes to an approximate token count, rounded up.
      def approx_tokens_from_byte_count(bytes)
        (Integer(bytes) + APPROX_BYTES_PER_TOKEN - 1) / APPROX_BYTES_PER_TOKEN
      end

      # Keeps text within budget or produces a middle-truncated
      # UTF-8 string and the original approximate token count.
      def truncate_middle_with_token_budget(text, max_tokens)
        content = utf8_content(text)
        max_tokens = Integer(max_tokens)
        max_bytes = approx_bytes_for_tokens(max_tokens)
        return [content, nil] if max_tokens.positive? && content.bytesize <= max_bytes

        prefix, suffix = split_string(content, max_bytes / 2, max_bytes - (max_bytes / 2))
        removed_tokens = approx_tokens_from_byte_count([content.bytesize - max_bytes, 0].max)
        truncated = "#{prefix}…#{removed_tokens} tokens truncated…#{suffix}"
        [truncated, approx_token_count(content)]
      end

      def split_string(content, beginning_bytes, end_bytes) # :nodoc:
        total_bytes = content.bytesize
        prefix_end = [beginning_bytes, total_bytes].min
        prefix_end -= 1 while prefix_end.positive? && continuation_byte?(content.getbyte(prefix_end))
        suffix_start = [total_bytes - end_bytes, 0].max
        suffix_start += 1 while suffix_start < total_bytes && continuation_byte?(content.getbyte(suffix_start))
        [content.byteslice(0, prefix_end), content.byteslice(suffix_start, total_bytes - suffix_start)]
      end
      private_class_method :split_string

      def continuation_byte?(byte) # :nodoc:
        byte && (byte & 0xc0) == 0x80
      end
      private_class_method :continuation_byte?

      def utf8_content(text) # :nodoc:
        content = String(text)
        return content if content.encoding == Encoding::UTF_8 && content.valid_encoding?
        if content.encoding == Encoding::ASCII_8BIT
          utf8 = content.dup.force_encoding(Encoding::UTF_8)
          return utf8 if utf8.valid_encoding?
        end

        content.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
      private_class_method :utf8_content
    end
  end
end
