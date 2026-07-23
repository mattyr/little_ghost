# frozen_string_literal: true

require "test_helper"

class SupportCallbacksTest < Minitest::Test
  def setup
    @callbacks = LittleGhost::Support::Callbacks.new(:before_model, :after_model, :before_tool, :after_tool)
  end

  def test_runs_callbacks_in_registration_order
    calls = []
    @callbacks.on(:before_model) do |_payload|
      calls << :first
      nil
    end
    @callbacks.on(:before_model) do |_payload|
      calls << :second
      nil
    end

    decision = @callbacks.run(:before_model, "request")

    assert_equal %i[first second], calls
    assert_instance_of LittleGhost::Support::Callbacks::Continue, decision
  end

  def test_replacements_flow_through_later_callbacks
    seen = nil
    @callbacks.on(:after_model) { |payload| LittleGhost::Support::Callbacks.replace(payload.upcase) }
    @callbacks.on(:after_model) do |payload|
      seen = payload
      nil
    end

    decision = @callbacks.run(:after_model, "answer")

    assert_equal "ANSWER", seen
    assert_equal "ANSWER", decision.value
  end

  def test_cancel_stops_the_chain
    called = false
    @callbacks.on(:before_tool) { LittleGhost::Support::Callbacks.cancel("denied") }
    @callbacks.on(:before_tool) { called = true }

    decision = @callbacks.run(:before_tool, {})

    assert_equal "denied", decision.reason
    refute called
  end

  def test_passes_context_when_requested
    seen = nil
    @callbacks.on(:after_tool) do |_payload, context:|
      seen = context
      nil
    end

    @callbacks.run(:after_tool, "result", context: {trace_id: "123"})

    assert_equal({trace_id: "123"}, seen)
  end

  def test_rejects_invalid_phase_and_ignores_ordinary_return_values
    assert_raises(ArgumentError) { @callbacks.run(:unknown, nil) }

    @callbacks.on(:before_tool) { :stop }
    assert @callbacks.run(:before_tool, nil).continue?
  end

  def test_named_and_block_callbacks_run_against_the_receiver
    receiver = Struct.new(:seen) do
      def record(payload, context:)
        self.seen = [payload, context]
        LittleGhost::Support::Callbacks.continue
      end
    end.new
    @callbacks.on(:before_model, :record)
    @callbacks.on(:before_model) do |payload|
      seen << payload
      LittleGhost::Support::Callbacks.continue
    end

    @callbacks.run(:before_model, "request", context: "context", receiver:)

    assert_equal ["request", "context", "request"], receiver.seen
  end
end
