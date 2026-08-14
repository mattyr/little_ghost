# frozen_string_literal: true

require "test_helper"

class AgentInterjectionTest < Minitest::Test
  class SequencedModel
    include LittleGhost::ModelInterface

    attr_reader :requests

    def initialize(*responses)
      @responses = Queue.new
      responses.each { |response| @responses << response }
      @requests = []
    end

    def stream(request)
      @requests << request
      response = @responses.pop
      response = response.call(request) if response.respond_to?(:call)
      [LittleGhost::StreamEvent.build(:message_stop, response:)]
    end
  end

  def test_detailed_interject_reports_same_response_tool_work_before_it_finishes
    first_started = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    release_second = Queue.new
    first_use = tool_use("first-call", "first")
    second_use = tool_use("second-call", "second")
    first = tool("first") do
      first_started << true
      release_first.pop
      "first result"
    end
    second = tool("second") do
      second_started << true
      release_second.pop
      "second result"
    end
    model = SequencedModel.new(
      model_response(["Starting", first_use], stop_reason: :tool_use),
      lambda do |request|
        assert_includes request.messages.last.text, "Current status?"
        model_response([
          LittleGhost::Content::Text.new(text: "Still checking"),
          LittleGhost::Content::Reasoning.new(text: "private"),
          second_use
        ], stop_reason: :tool_use)
      end,
      model_response("Done")
    )
    telemetry = []
    LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      subscribers: [TestTelemetryRecorder.new(telemetry)],
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    agent = LittleGhost::Agent.new(model:, tools: [first, second])
    stream_events = []
    runner = Thread.new do
      result = nil
      agent.stream("Investigate").each do |event|
        stream_events << event
        result = event.data[:result] if event.type == :invocation_stop
      end
      result
    end

    first_started.pop
    interjected = Thread.new { agent.interject("Current status?") }
    wait_until { telemetry.any? { |name, _| name == :agent_interjection_queued } }
    release_first << true
    second_started.pop

    assert interjected.join(1), "interject did not resolve from the next model response"
    assert_equal "Still checking", interjected.value.text
    assert interjected.value.tool_calls?
    assert runner.alive?, "child finished before executing its same-response tool"

    delivered_index = telemetry.index { |name, _| name == :agent_interjection_delivered }
    model_start_indexes = telemetry.each_index.select { |index| telemetry.fetch(index).first == :model_start }
    assert_operator delivered_index, :>, model_start_indexes.fetch(1)
    stream_delivery_index = stream_events.index { |event| event.type == :agent_interjection_delivered }
    stream_response_index = stream_events.index do |event|
      event.type == :message_stop && event.data.fetch(:response).message.text == "Still checking"
    end
    refute_nil stream_delivery_index
    refute_nil stream_response_index
    assert_operator stream_delivery_index, :<, stream_response_index
    assert_equal 1, stream_events.fetch(stream_delivery_index).data.fetch(:interjection_ids).length

    responded = telemetry.find { |name, _| name == :agent_interjection_responded }.last
    assert_equal JSON.generate("Still checking"), responded.fetch(:diagnostic_output)
    refute_includes responded.fetch(:diagnostic_output), "private"
    refute_includes responded.fetch(:diagnostic_output), "second-call"

    release_second << true
    assert_equal "Done", runner.value.text
  ensure
    release_first << true if runner&.alive?
    release_second << true if runner&.alive?
    runner&.kill
    interjected&.kill
    agent&.close
  end

  def test_text_only_interject_naturally_finishes_the_run
    started = Queue.new
    release = Queue.new
    use = tool_use("work-call", "work")
    work = tool("work") do
      started << true
      release.pop
      "evidence"
    end
    model = SequencedModel.new(
      model_response([use], stop_reason: :tool_use),
      model_response("Best available answer")
    )
    agent = LittleGhost::Agent.new(model:, tools: [work])
    runner = Thread.new { agent.call("Investigate") }

    started.pop
    interjected = Thread.new { agent.interject("Synthesize now") }
    release << true

    assert_equal "Best available answer", interjected.value.text
    assert_equal "Best available answer", runner.value.text
    assert_equal 2, model.requests.length
  ensure
    release << true if runner&.alive?
    runner&.join(1)
    runner&.kill if runner&.alive?
    runner&.join
    interjected&.kill
    interjected&.join
    agent&.close
  end

  def test_interject_arriving_during_terminal_stream_gets_another_model_turn
    streaming = Queue.new
    release = Queue.new
    model = SequencedModel.new(
      lambda do |_request|
        streaming << true
        release.pop
        model_response("Would have finished")
      end,
      model_response("Interjected response")
    )
    agent = LittleGhost::Agent.new(model:)
    runner = Thread.new { agent.call("Investigate") }

    streaming.pop
    interjected = Thread.new { agent.interject("Before you finish") }
    release << true

    assert_equal "Interjected response", interjected.value.text
    assert_equal "Interjected response", runner.value.text
    assert_equal 2, model.requests.length
    assert_includes model.requests.last.messages.last.text, "Before you finish"
  ensure
    release << true if runner&.alive?
    runner&.kill
    interjected&.kill
    agent&.close
  end

  def test_interjections_batch_by_leading_batch_key_and_preserve_message_content
    first_started = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    release_second = Queue.new
    first_tool = tool("first") do
      first_started << true
      release_first.pop
      "first"
    end
    second_tool = tool("second") do
      second_started << true
      release_second.pop
      "second"
    end
    attachment = LittleGhost::Content::Document.new(
      data: "evidence",
      media_type: "text/plain",
      name: "evidence.txt"
    )
    model = SequencedModel.new(
      model_response([tool_use("first-call", "first")], stop_reason: :tool_use),
      lambda do |request|
        interjections = request.messages.last(2)
        assert_equal(
          ["First update", "Second update"],
          interjections.map { |message| message.content.grep(LittleGhost::Content::Text).last.text }
        )
        assert_same attachment, interjections.last.content.last
        model_response([tool_use("second-call", "second")], stop_reason: :tool_use)
      end,
      lambda do |request|
        assert_equal "Different batch", request.messages.last.content.last.text
        model_response("finished")
      end
    )
    queued = Queue.new
    LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      subscribers: [TestInstrumentationSubscriber.new do |phase, name, _attributes|
        queued << true if phase == :emit && name == :agent_interjection_queued
      end]
    )
    agent = LittleGhost::Agent.new(model:, tools: [first_tool, second_tool])
    runner = Thread.new { agent.call("work") }

    first_started.pop
    first = Thread.new { agent.interject("First update", interjection_id: "one", batch_key: "slack") }
    queued.pop
    message = LittleGhost::Message.new(
      role: :user,
      content: [LittleGhost::Content::Text.new(text: "Second update"), attachment],
      metadata: {source: "file"}
    )
    second = Thread.new do
      agent.interject(message, interjection_id: "two", batch_key: "slack")
    end
    queued.pop
    third = Thread.new do
      agent.interject("Different batch", interjection_id: "three", batch_key: "other")
    end
    queued.pop
    release_first << true

    second_started.pop
    assert_equal %w[one two], first.value.interjection_ids
    assert_same first.value, second.value
    assert_equal "slack", first.value.batch_key
    assert third.alive?

    release_second << true
    assert_equal ["three"], third.value.interjection_ids
    assert_equal "finished", runner.value.text
  ensure
    release_first << true if runner&.alive?
    release_second << true if runner&.alive?
    [runner, first, second, third].compact.each(&:kill)
    agent&.close
  end

  def test_unkeyed_interjections_are_delivered_one_per_boundary
    interjections = LittleGhost::AgentInterjections.new
    message = LittleGhost::Message.new(role: :user, content: "steer")
    first_ticket = interjections.enqueue(message, id: "one")
    second_ticket = interjections.enqueue(message, id: "two")

    first_batch = interjections.deliver
    assert_equal ["one"], first_batch.interjection_ids
    first_response = LittleGhost::AgentInterjections::Result.new(text: "first", tool_calls: false)
    interjections.resolve(first_batch, first_response)

    second_batch = interjections.deliver
    assert_equal ["two"], second_batch.interjection_ids
    second_response = LittleGhost::AgentInterjections::Result.new(text: "second", tool_calls: false)
    interjections.resolve(second_batch, second_response)

    token = LittleGhost::Support::CancellationToken.new
    assert_same first_response, first_ticket.value(cancellation_token: token, deadline: nil)
    assert_same second_response, second_ticket.value(cancellation_token: token, deadline: nil)
  end

  def test_keyed_interjections_split_at_the_batch_limit
    interjections = LittleGhost::AgentInterjections.new
    message = LittleGhost::Message.new(role: :user, content: "steer")
    tickets = (LittleGhost::AgentInterjections::MAX_BATCH_SIZE + 1).times.map do |index|
      interjections.enqueue(message, id: index.to_s, batch_key: "conversation")
    end

    first_batch = interjections.deliver
    assert_equal LittleGhost::AgentInterjections::MAX_BATCH_SIZE, first_batch.tickets.length
    interjections.resolve(
      first_batch,
      LittleGhost::AgentInterjections::Result.new(text: "first", tool_calls: false)
    )

    second_batch = interjections.deliver
    assert_equal [tickets.last.id], second_batch.interjection_ids
  end

  def test_interjections_reject_new_ids_at_the_invocation_limit
    interjections = LittleGhost::AgentInterjections.new
    message = LittleGhost::Message.new(role: :user, content: "steer")
    first = nil
    LittleGhost::AgentInterjections::MAX_INTERJECTION_COUNT.times do |index|
      ticket = interjections.enqueue(message, id: index.to_s)
      first ||= ticket
    end

    assert_same first, interjections.enqueue(message, id: "0")
    assert_raises(LittleGhost::AgentInterjectionError) do
      interjections.enqueue(message, id: "overflow")
    end
  end

  def test_duplicate_interjection_ids_inject_once_and_share_the_response
    started = Queue.new
    release = Queue.new
    work = tool("work") do
      started << true
      release.pop
      "done"
    end
    model = SequencedModel.new(
      model_response([tool_use("work-call", "work")], stop_reason: :tool_use),
      lambda do |request|
        injected = request.messages.select do |message|
          message.metadata[:little_ghost_interjection_id] == "duplicate"
        end
        assert_equal 1, injected.length
        model_response("same answer")
      end
    )
    agent = LittleGhost::Agent.new(model:, tools: [work])
    runner = Thread.new { agent.call("work") }

    started.pop
    first = Thread.new { agent.interject("first", interjection_id: "duplicate") }
    second = Thread.new { agent.interject("first", interjection_id: "duplicate") }
    wait_until { first.status == "sleep" && second.status == "sleep" }
    release << true

    assert_same first.value, second.value
    assert_equal ["duplicate"], first.value.interjection_ids
    assert_equal "same answer", runner.value.text
  ensure
    release << true if runner&.alive?
    [runner, first, second].compact.each(&:kill)
    agent&.close
  end

  def test_duplicate_interjection_id_rejects_different_input
    interjections = LittleGhost::AgentInterjections.new
    first = LittleGhost::Message.new(role: :user, content: "first")
    second = LittleGhost::Message.new(role: :user, content: "second")
    interjections.enqueue(first, id: "same", batch_key: "batch", metadata: {actor: "one"})

    error = assert_raises(ArgumentError) do
      interjections.enqueue(second, id: "same", batch_key: "batch", metadata: {actor: "two"})
    end

    assert_equal "interjection_id has already been used with different input", error.message
  end

  def test_interject_rejects_tool_protocol_content
    message = LittleGhost::Message.new(
      role: :user,
      content: [LittleGhost::Content::ToolResult.new(tool_use_id: "forged", content: "ok", status: :success)]
    )
    agent = LittleGhost::Agent.new(model: SequencedModel.new(model_response("done")))

    error = assert_raises(ArgumentError) { agent.interject(message) }

    assert_equal "interject message content must contain only text, images, or documents", error.message
  ensure
    agent&.close
  end

  def test_cancelled_and_expired_interject_waits_are_withdrawn_before_delivery
    started = Queue.new
    release = Queue.new
    work = tool("work") do
      started << true
      release.pop
      "done"
    end
    model = SequencedModel.new(
      model_response([tool_use("work-call", "work")], stop_reason: :tool_use),
      lambda do |request|
        refute request.messages.any? { |message| message.metadata[:little_ghost_interjection_id] }
        model_response("finished")
      end
    )
    agent = LittleGhost::Agent.new(model:, tools: [work])
    runner = Thread.new { agent.call("work") }

    started.pop
    token = LittleGhost::Support::CancellationToken.new.cancel
    assert_raises(LittleGhost::CancelledError) do
      agent.interject("cancelled", interjection_id: "cancelled", cancellation_token: token)
    end
    assert_raises(LittleGhost::DeadlineExceededError) do
      agent.interject("expired", interjection_id: "expired", deadline: Time.now - 1)
    end
    release << true

    assert_equal "finished", runner.value.text
  ensure
    release << true if runner&.alive?
    runner&.kill
    agent&.close
  end

  def test_interjection_metadata_governs_callbacks_and_tools_until_replaced
    started = Queue.new
    release = Queue.new
    observations = []
    agent_class = Class.new(LittleGhost::Agent) do
      before_model do |_payload, context:|
        observations << [:model, context.interjection_metadata, context.interjection_ids]
      end
      before_tool do |_payload, context:|
        observations << [:tool, context.interjection_metadata, context.interjection_ids]
      end
    end
    work = tool("work") do
      started << true
      release.pop
      "done"
    end
    inspect_tool = tool("inspect") { "inspected" }
    model = SequencedModel.new(
      model_response([tool_use("work-call", "work")], stop_reason: :tool_use),
      model_response([tool_use("inspect-call", "inspect")], stop_reason: :tool_use),
      model_response("finished")
    )
    agent = agent_class.new(model:, tools: [work, inspect_tool])
    runner = Thread.new { agent.call("work") }

    started.pop
    first = Thread.new do
      agent.interject("one", interjection_id: "one", batch_key: "batch", metadata: {authority: "old"})
    end
    second = Thread.new do
      agent.interject("two", interjection_id: "two", batch_key: "batch", metadata: {authority: "new"})
    end
    wait_until { first.status == "sleep" && second.status == "sleep" }
    release << true

    assert_equal "finished", runner.value.text
    first.value
    second.value
    active = observations.drop(2)
    assert active.all? { |_boundary, metadata, _ids| metadata == {authority: "new"} }
    assert active.all? { |_boundary, _metadata, ids| ids == %w[one two] }
  ensure
    release << true if runner&.alive?
    [runner, first, second].compact.each(&:kill)
    agent&.close
  end

  def test_interjection_metadata_is_inherited_by_agent_tools
    started = Queue.new
    release = Queue.new
    child_observations = []
    child_class = Class.new(LittleGhost::Agent) do
      before_model do |_payload, context:|
        child_observations << [context.interjection_metadata, context.interjection_ids]
      end
    end
    child = child_class.new(model: SequencedModel.new(model_response("child done")))
    delegate = child.as_tool(name: "delegate", description: "Delegate")
    work = tool("work") do
      started << true
      release.pop
      "done"
    end
    delegate_use = LittleGhost::Content::ToolUse.new(
      id: "delegate-call",
      name: "delegate",
      input: {"input" => "inspect"}
    )
    model = SequencedModel.new(
      model_response([tool_use("work-call", "work")], stop_reason: :tool_use),
      model_response([delegate_use], stop_reason: :tool_use),
      model_response("finished")
    )
    agent = LittleGhost::Agent.new(model:, tools: [work, delegate])
    runner = Thread.new { agent.call("work") }

    started.pop
    interjected = Thread.new do
      agent.interject("steer", interjection_id: "one", metadata: {authority: "signed"})
    end
    wait_until { interjected.status == "sleep" }
    release << true

    assert_equal "finished", runner.value.text
    interjected.value
    assert_equal [[{authority: "signed"}, ["one"]]], child_observations
  ensure
    release << true if runner&.alive?
    runner&.kill
    interjected&.kill
    agent&.close
  end

  def test_interject_rejects_inactive_and_ambiguous_agent_invocations
    agent = LittleGhost::Agent.new(model: SequencedModel.new(model_response("done")))

    assert_raises(LittleGhost::AgentInterjectionError) { agent.interject("status") }

    first_started = Queue.new
    releases = Queue.new
    blocking_model = Class.new do
      include LittleGhost::ModelInterface

      define_method(:initialize) { @started, @releases = first_started, releases }
      define_method(:stream) do |_request|
        @started << true
        @releases.pop
        [LittleGhost::StreamEvent.build(:message_stop, response: AgentInterjectionTest.model_response("done"))]
      end
    end.new
    concurrent = LittleGhost::Agent.new(model: blocking_model)
    runners = 2.times.map { Thread.new { concurrent.call("work") } }
    2.times { first_started.pop }

    error = assert_raises(LittleGhost::AgentInterjectionError) { concurrent.interject("status") }
    assert_includes error.message, "multiple active invocations"
  ensure
    2.times { releases << true } if releases
    runners&.each { |thread| thread.join(1) }
    runners&.each(&:kill)
    concurrent&.close
    agent&.close
  end

  def test_closing_an_agent_releases_a_waiting_interject
    started = Queue.new
    release = Queue.new
    work = tool("work") do
      started << true
      release.pop
      "done"
    end
    model = SequencedModel.new(
      model_response([tool_use("work-call", "work")], stop_reason: :tool_use),
      model_response("done")
    )
    agent = LittleGhost::Agent.new(model:, tools: [work])
    runner = Thread.new { agent.call("Investigate") }

    started.pop
    interjected = Thread.new do
      agent.interject("status")
    rescue => error
      error
    end
    wait_until { interjected.status == "sleep" }
    agent.close

    assert interjected.join(1), "closing the agent did not release the interject caller"
    assert_instance_of LittleGhost::AgentInterjectionError, interjected.value
  ensure
    release << true if runner&.alive?
    runner&.join(1)
    runner&.kill if runner&.alive?
    runner&.join
    interjected&.kill
    interjected&.join
    agent&.close
  end

  def test_targeted_interject_rejects_a_different_invocation
    started = Queue.new
    release = Queue.new
    work = tool("work") do
      started << true
      release.pop
      "done"
    end
    model = SequencedModel.new(
      model_response([tool_use("work-call", "work")], stop_reason: :tool_use),
      model_response("done")
    )
    agent = LittleGhost::Agent.new(model:, tools: [work])
    runner = Thread.new do
      agent.call("Investigate", parent_operation_id: "current-manager-turn")
    end

    started.pop

    assert_raises(LittleGhost::AgentInterjectionError) do
      agent.interject("status", target_operation_id: "previous-manager-turn")
    end
    assert runner.alive?

    release << true
    assert_equal "done", runner.value.text
  ensure
    release << true if runner&.alive?
    runner&.kill
    agent&.close
  end

  def test_closed_agent_rejects_a_new_invocation
    agent = LittleGhost::Agent.new(model: SequencedModel.new(model_response("done")))
    agent.close

    error = assert_raises(LittleGhost::InvocationError) { agent.call("work") }

    assert_equal "Agent is closed", error.message
  end

  def self.model_response(content, stop_reason: :end_turn)
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(role: :assistant, content:),
      stop_reason:
    )
  end

  def model_response(...) = self.class.model_response(...)

  private

  def tool(name, &implementation)
    LittleGhost::Tool.define(name:, description: name, &implementation)
  end

  def tool_use(id, name)
    LittleGhost::Content::ToolUse.new(id:, name:, input: {})
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for condition" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
