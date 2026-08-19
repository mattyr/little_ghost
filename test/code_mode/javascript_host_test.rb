# frozen_string_literal: true

require "stringio"
require "timeout"
require "test_helper"
require "little_ghost/code_mode/javascript/host"

class CodeModeHostTest < Minitest::Test
  FakeProgram = Data.define(:id) do
    def deliver(*) = nil
    def terminate = nil
  end

  def test_host_controls_are_lexical_and_model_runtime_apis_are_unavailable
    messages = run_program(<<~JAVASCRIPT)
      text({
        hostControls: Object.getOwnPropertyNames(globalThis).filter((name) => name.startsWith("__littleGhost")),
        oldControls: [typeof __littleGhostDrain, typeof __littleGhostResolve, typeof __littleGhostRun],
        process: typeof process,
        require: typeof require,
        fetch: typeof fetch,
        console: typeof console,
        wasm: typeof WebAssembly,
        binaryMemory: [
          typeof ArrayBuffer,
          typeof SharedArrayBuffer,
          typeof DataView,
          typeof Atomics,
          typeof Int8Array,
          typeof Uint8Array,
          typeof Uint8ClampedArray,
          typeof Int16Array,
          typeof Uint16Array,
          typeof Int32Array,
          typeof Uint32Array,
          typeof BigInt64Array,
          typeof BigUint64Array,
          typeof Float32Array,
          typeof Float64Array
        ]
      });
    JAVASCRIPT

    output = JSON.parse(messages.find { |message| message[:type] == "output" }.fetch(:value))
    assert_empty output.fetch("hostControls")
    assert_equal ["undefined", "undefined", "undefined"], output.fetch("oldControls")
    assert_equal "undefined", output.fetch("process")
    assert_equal "undefined", output.fetch("require")
    assert_equal "undefined", output.fetch("fetch")
    assert_equal "undefined", output.fetch("console")
    assert_equal "undefined", output.fetch("wasm")
    assert_equal Array.new(15, "undefined"), output.fetch("binaryMemory")
    assert_equal "complete", messages.last.fetch(:type)
  end

  def test_model_source_cannot_access_bootstrap_closure_state
    messages = run_program(<<~JAVASCRIPT)
      text([
        typeof definitions,
        typeof definitionIndex,
        typeof calls,
        typeof outputs,
        typeof yields,
        typeof pending,
        typeof exitSignal
      ]);
    JAVASCRIPT

    output = JSON.parse(messages.find { |message| message[:type] == "output" }.fetch(:value))
    assert_equal Array.new(7, "undefined"), output
    assert_equal "complete", messages.last.fetch(:type)
  end

  def test_tool_metadata_cannot_reveal_the_private_control_identifier
    marker = "__LITTLE_GHOST_CONTROL_IDENTIFIER__"
    messages = run_program(
      "text(ALL_TOOLS[0].description);",
      tools: [{"name" => "echo", "description" => marker, "input_schema" => {"type" => "object"}}]
    )

    assert_equal marker, messages.find { |message| message[:type] == "output" }.fetch(:value)
    assert_equal "complete", messages.last.fetch(:type)
  end

  def test_public_catalog_contains_only_names_and_descriptions
    messages = run_program(
      "text({catalog: ALL_TOOLS, keys: Object.keys(ALL_TOOLS[0]).sort()});",
      tools: [{
        "name" => "echo",
        "description" => "Echo input",
        "input_schema" => {"type" => "object"},
        "canonical_name" => "gateway___echo"
      }]
    )

    output = JSON.parse(messages.find { |message| message[:type] == "output" }.fetch(:value))
    assert_equal [{"name" => "echo", "description" => "Echo input"}], output.fetch("catalog")
    assert_equal ["description", "name"], output.fetch("keys")
  end

  def test_runner_accepts_a_full_parallel_batch_and_rejects_the_next_program
    output = StringIO.new("".b)
    runner = LittleGhost::CodeMode::Javascript::Host::Runner.new(input: StringIO.new, output:)

    LittleGhost::CodeMode::Javascript::Host::Program.stub(:new, ->(**arguments) { FakeProgram.new(arguments.fetch(:id)) }) do
      9.times do |index|
        runner.send(
          :receive,
          {"type" => "execute", "program_id" => index.to_s, "source" => "", "tools" => []}
        )
      end
    end

    output.rewind
    messages = Array.new(1) { LittleGhost::CodeMode::Protocol.read(output) }
    assert_equal 8, LittleGhost::CodeMode::Javascript::Host::MAX_ACTIVE_PROGRAMS
    assert_equal(
      {
        "type" => "failed",
        "program_id" => "8",
        "error" => "Code-mode host has too many active programs",
        "fatal" => true
      },
      messages.first
    )
  end

  def test_runner_rejects_source_above_the_byte_limit_before_starting_a_program
    output = StringIO.new("".b)
    runner = LittleGhost::CodeMode::Javascript::Host::Runner.new(input: StringIO.new, output:)
    source = "a" * (LittleGhost::CodeMode::Javascript::Host::MAX_SOURCE_BYTES + 1)

    runner.send(
      :receive,
      {"type" => "execute", "program_id" => "oversized", "source" => source, "tools" => []}
    )

    output.rewind
    message = LittleGhost::CodeMode::Protocol.read(output)
    assert_equal "failed", message.fetch("type")
    assert_equal "oversized", message.fetch("program_id")
    assert_equal true, message.fetch("fatal")
    assert_equal(
      "Invalid code-mode request: Code-mode source exceeds the size limit",
      message.fetch("error")
    )
  end

  def test_termination_does_not_wait_for_context_disposal
    disposal_started = Queue.new
    disposal_release = Queue.new
    messages = Queue.new
    finished = Queue.new
    context = Object.new
    context.define_singleton_method(:eval) do |source, **|
      next({"outputs" => [], "calls" => [], "done" => true, "failure" => nil}) if source.include?(".drain(")

      nil
    end
    context.define_singleton_method(:stop) { nil }
    context.define_singleton_method(:dispose) do
      disposal_started << true
      disposal_release.pop
    end

    MiniRacer::Context.stub(:new, context) do
      program = LittleGhost::CodeMode::Javascript::Host::Program.new(
        id: "blocked-cleanup",
        source: "1",
        tools: [],
        writer: ->(**message) { messages << message },
        finished: ->(*) { finished << true }
      )
      Timeout.timeout(1) { disposal_started.pop }

      termination = Thread.new { program.terminate }
      assert termination.join(0.2), "termination waited for JavaScript context disposal"
      assert_nil messages.pop(timeout: 0.05)

      disposal_release << true
      terminal = Timeout.timeout(1) { messages.pop }
      assert_equal "complete", terminal.fetch(:type)
      assert program.join(1), "JavaScript host program did not finish after disposal"
      assert Timeout.timeout(1) { finished.pop }
    ensure
      disposal_release << true if disposal_release.empty?
      termination&.join(0.5)
      program&.terminate
      program&.join(0.5)
    end
  end

  def test_context_disposal_failure_replaces_a_successful_terminal_result
    messages = Queue.new
    finished = Queue.new
    context = Object.new
    context.define_singleton_method(:eval) do |source, **|
      next({"outputs" => [], "calls" => [], "done" => true, "failure" => nil}) if source.include?(".drain(")

      nil
    end
    context.define_singleton_method(:dispose) { raise "sensitive cleanup detail" }

    MiniRacer::Context.stub(:new, context) do
      program = LittleGhost::CodeMode::Javascript::Host::Program.new(
        id: "failed-cleanup",
        source: "1",
        tools: [],
        writer: ->(**message) { messages << message },
        finished: ->(*) { finished << true }
      )
      terminal = Timeout.timeout(1) { messages.pop }

      assert_equal "failed", terminal.fetch(:type)
      assert_equal true, terminal.fetch(:fatal)
      assert_equal "JavaScript context cleanup failed", terminal.fetch(:error)
      refute_includes terminal.fetch(:error), "sensitive cleanup detail"
      assert program.join(1), "JavaScript host program did not finish after failed disposal"
      assert Timeout.timeout(1) { finished.pop }
    end
  end

  def test_program_id_remains_reserved_until_terminal_result_is_written
    write_started = Queue.new
    write_release = Queue.new
    finished = Queue.new
    context = Object.new
    context.define_singleton_method(:eval) do |source, **|
      next({"outputs" => [], "calls" => [], "done" => true, "failure" => nil}) if source.include?(".drain(")

      nil
    end
    context.define_singleton_method(:dispose) { nil }

    MiniRacer::Context.stub(:new, context) do
      program = LittleGhost::CodeMode::Javascript::Host::Program.new(
        id: "reserved",
        source: "1",
        tools: [],
        writer: ->(**) do
          write_started << true
          write_release.pop
        end,
        finished: ->(*) { finished << true }
      )
      Timeout.timeout(1) { write_started.pop }

      assert_nil finished.pop(timeout: 0.05)

      write_release << true
      assert program.join(1), "JavaScript host program did not finish after writing its terminal result"
      assert Timeout.timeout(1) { finished.pop }
    ensure
      write_release << true if write_release.empty?
      program&.terminate
      program&.join(0.5)
    end
  end

  private

  def run_program(source, tools: [])
    messages = Queue.new
    program = LittleGhost::CodeMode::Javascript::Host::Program.new(
      id: "test-program",
      source:,
      tools:,
      writer: ->(**message) { messages << message },
      finished: ->(*) {}
    )

    collected = Timeout.timeout(2) do
      [].tap do |result|
        loop do
          result << messages.pop
          break if %w[complete failed terminated].include?(result.last.fetch(:type))
        end
      end
    end
    assert program.join(2), "JavaScript host program did not finish after its terminal result"
    collected
  ensure
    program&.terminate
    program&.join(0.5)
  end
end
