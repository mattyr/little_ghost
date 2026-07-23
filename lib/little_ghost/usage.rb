# frozen_string_literal: true

module LittleGhost
  class Usage
    FIELDS = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens reasoning_tokens].freeze

    attr_reader(*FIELDS)

    def initialize(input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, reasoning_tokens: 0)
      @input_tokens = integer(input_tokens)
      @output_tokens = integer(output_tokens)
      @cache_read_tokens = integer(cache_read_tokens)
      @cache_write_tokens = integer(cache_write_tokens)
      @reasoning_tokens = integer(reasoning_tokens)
    end

    def total_tokens
      FIELDS.sum { |field| public_send(field) }
    end

    def +(other)
      self.class.new(**FIELDS.to_h { |field| [field, public_send(field) + other.public_send(field)] })
    end

    def to_h
      FIELDS.to_h { |field| [field, public_send(field)] }.merge(total_tokens: total_tokens)
    end

    private

    def integer(value)
      [Integer(value || 0), 0].max
    rescue ArgumentError, TypeError
      0
    end
  end
end
