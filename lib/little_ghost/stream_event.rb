# frozen_string_literal: true

module LittleGhost
  StreamEvent = Data.define(:type, :data) do # :nodoc:
    # Creates an event with a symbol +type+ and frozen outer payload Hash.
    def self.build(type, **data)
      new(type: type.to_sym, data: data.freeze)
    end
  end

  # StreamEvent gives every provider and interface the same language for live
  # agent output. Consumers can handle text, reasoning, tools, usage, retries,
  # and completion without branching on a provider SDK.
  #
  # Providers emit events such as +:message_start+, +:text_delta+,
  # +:reasoning_delta+, +:tool_call_start+, +:tool_call_delta+,
  # +:tool_call_stop+, +:usage+, +:model_retry+, and +:message_stop+. The
  # terminal event carries a {ModelResponse}[rdoc-ref:LittleGhost::ModelResponse]
  # in +data[:response]+. An +:agent_stream+ event wraps a copied, frozen Agent
  # event with an
  # AgentStreamSource[rdoc-ref:LittleGhost::AgentStreamSource] when a Run exposes
  # nested work.
  #
  #   event = LittleGhost::StreamEvent.build(:text_delta, text: "Hello")
  #   event.type        # => :text_delta
  #   event.data[:text] # => "Hello"
  class StreamEvent < Data # :doc:
    ##
    # :attr_reader: type
    # The event kind, such as +:text_delta+, +:usage+, or +:message_stop+.

    ##
    # :attr_reader: data
    # The frozen outer payload Hash. Nested values are retained and must not be
    # mutated by callers.

    ##
    # :singleton-method: build
    # :call-seq:
    #   build(type, **data) -> StreamEvent
    #
    # Creates an event with a symbol +type+ and frozen outer payload Hash.
  end
end
