# frozen_string_literal: true

require "stringio"
require "test_helper"
require "little_ghost/hosting"

class HostingTest < Minitest::Test
  class StubbornProvider
    attr_reader :cleanup_started, :producer_started, :release

    def initialize
      @cleanup_started = Queue.new
      @producer_started = Queue.new
      @release = Queue.new
    end

    def stream(request)
      Enumerator.new do |events|
        stream = LittleGhost::Support::InterruptibleStream.new(
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        ) do
          producer_started << Thread.current
          Queue.new.pop
        ensure
          cleanup_started << true
          release.pop
        end
        stream.each { |event| events << event }
      end
    end
  end

  class RunApplication
    attr_reader :instrumentation

    def initialize(provider)
      @provider = provider
      @instrumentation = LittleGhost::Support::Instrumentation.new(logger: Logger.new(IO::NULL))
    end

    def open_session(_run) = nil

    def build_agent(run:)
      LittleGhost::Agent.new(model: @provider, instrumentation:)
    end

    def template_locals(run:, agent:) = {}
    def error_message(error, _run) = "run failed: #{error.class}"
  end

  def test_accepts_invocation_and_reports_busy_health
    started = Queue.new
    release = Queue.new
    host = build_host do |invocation, _environment|
      started << invocation
      release.pop
    end

    response = host.call(environment("POST", "/invocations", {input: "hello"}))
    invocation = started.pop
    ping = host.call(environment("GET", "/ping"))
    release << true
    host.wait

    assert_equal 202, response.first
    assert_equal "hello", invocation.fetch("input")
    assert_equal({"status" => "HealthyBusy"}, JSON.parse(ping.last.join))
  end

  def test_rejects_invalid_json_and_unknown_paths
    host = build_host { nil }

    invalid = host.call({"REQUEST_METHOD" => "POST", "PATH_INFO" => "/invocations", "rack.input" => StringIO.new("{")})
    missing = host.call(environment("GET", "/missing"))

    assert_equal 400, invalid.first
    assert_equal 404, missing.first
  end

  def test_normalizes_with_an_immutable_request_environment
    seen = []
    started = Queue.new
    release = Queue.new
    host = build_host(
      normalize: ->(payload, environment) { payload.merge("request_id" => environment.fetch("HTTP_X_REQUEST_ID")) }
    ) do |invocation, request_environment|
      started << true
      release.pop
      seen << [invocation, request_environment]
    end
    request = environment("POST", "/invocations", {input: "hello"})
    request["HTTP_X_REQUEST_ID"] = +"request-1"

    assert_equal 202, host.call(request).first
    started.pop
    request["HTTP_X_REQUEST_ID"].replace("changed")
    request.fetch("rack.input").close
    release << true
    host.wait

    assert_equal "request-1", seen.first.first.fetch("request_id")
    assert_equal "request-1", seen.first.last.fetch("HTTP_X_REQUEST_ID")
    assert_predicate seen.first.last, :frozen?
    refute_includes seen.first.last, "rack.input"
  end

  def test_bounds_request_size_and_pending_invocations_when_configured
    started = Queue.new
    release = Queue.new
    accepted = 0
    host = build_host(
      max_request_bytes: 10,
      max_pending_invocations: 1,
      accepted_response: lambda do |_invocation|
        accepted += 1
        {status: "running"}
      end
    ) do
      started << true
      release.pop
    end

    first = host.call(environment("POST", "/invocations", {}))
    started.pop
    second = host.call(environment("POST", "/invocations", {}))
    oversized = host.call({
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/invocations",
      "CONTENT_LENGTH" => "11",
      "rack.input" => StringIO.new("{}")
    })
    release << true
    host.wait

    assert_equal 202, first.first
    assert_equal 429, second.first
    assert_equal 413, oversized.first
    assert_equal 1, accepted
  end

  def test_accepts_more_than_eight_pending_invocations_by_default
    started = Queue.new
    release = Queue.new
    host = build_host do
      started << true
      release.pop
    end

    responses = 9.times.map { host.call(environment("POST", "/invocations", {})) }
    9.times { started.pop }
    9.times { release << true }
    host.wait

    assert_equal [202], responses.map(&:first).uniq
  end

  def test_registers_a_fast_background_task_before_it_can_finish
    entered = Queue.new
    registered = Queue.new
    host = nil
    host = build_host do
      entered << true
      registered << host.instance_variable_get(:@mutex).synchronize do
        host.instance_variable_get(:@tasks).include?(Thread.current)
      end
    end
    spawn = Thread.method(:new)

    response = Thread.stub(:new, lambda { |&work|
      task = spawn.call(&work)
      entered.pop
      task
    }) do
      host.call(environment("POST", "/invocations", {}))
    end
    host.wait

    assert_equal 202, response.first
    assert_equal true, registered.pop
    assert_empty host.instance_variable_get(:@tasks)
    refute host.busy?
  end

  def test_cleanup_failure_keeps_runtime_busy_and_rejects_further_invocations
    cleanup_error = LittleGhost::CleanupError.new("invocation work is still running")
    host = build_host(logger: Logger.new(IO::NULL)) { raise cleanup_error }

    first = host.call(environment("POST", "/invocations", {}))
    host.wait
    ping = host.call(environment("GET", "/ping"))
    second = host.call(environment("POST", "/invocations", {}))

    assert_equal 202, first.first
    assert host.busy?
    assert_equal({"status" => "HealthyBusy"}, JSON.parse(ping.last.join))
    assert_equal 429, second.first
  end

  def test_stubborn_run_producer_poisons_runtime
    provider = StubbornProvider.new
    application = RunApplication.new(provider)
    run = LittleGhost::Run.new(
      invocation: LittleGhost::Invocation.new(message: "hello"),
      application:
    )
    host = build_host(logger: Logger.new(IO::NULL)) { run.call }

    first = host.call(environment("POST", "/invocations", {}))
    worker = provider.producer_started.pop
    run.cancellation_token.cancel
    provider.cleanup_started.pop
    host.wait
    second = host.call(environment("POST", "/invocations", {}))

    assert_equal 202, first.first
    assert_instance_of LittleGhost::Support::InterruptibleStream::CleanupError, run.error
    assert worker.alive?, "stubborn producer unexpectedly stopped before being released"
    assert host.busy?
    assert_equal 429, second.first
  ensure
    provider&.release&.push(true) if worker&.alive?
    worker&.join(1)
  end

  def test_ordinary_invocation_failure_does_not_poison_runtime
    attempts = 0
    host = build_host(logger: Logger.new(IO::NULL)) do
      attempts += 1
      raise "failed" if attempts == 1
    end

    first = host.call(environment("POST", "/invocations", {}))
    host.wait
    second = host.call(environment("POST", "/invocations", {}))
    host.wait

    assert_equal 202, first.first
    assert_equal 202, second.first
    assert_equal 2, attempts
    refute host.busy?
  end

  def test_rejects_at_capacity_before_reading_the_request
    started = Queue.new
    release = Queue.new
    host = build_host(max_pending_invocations: 1) do
      started << true
      release.pop
    end

    host.call(environment("POST", "/invocations", {}))
    started.pop
    unread = Object.new
    unread.define_singleton_method(:read) { |_limit| raise "request body was read" }

    response = host.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/invocations", "rack.input" => unread)
    release << true
    host.wait

    assert_equal 429, response.first
  end

  def test_subclasses_format_errors_and_do_not_start_when_acceptance_fails
    calls = 0
    host = build_host(
      normalize: ->(*) { raise ArgumentError, "internal secret" },
      error_response: ->(status:, message:, error:) { {detail: message} }
    ) { calls += 1 }

    response = host.call(environment("POST", "/invocations", {}))

    assert_equal 400, response.first
    assert_equal({"detail" => "Request is invalid"}, JSON.parse(response.last.join))
    assert_equal 0, calls

    acceptance_failure = build_host(
      accepted_response: ->(_invocation) { raise ArgumentError, "cannot serialize" }
    ) { calls += 1 }
    assert_raises(ArgumentError) do
      acceptance_failure.call(environment("POST", "/invocations", {}))
    end
    assert_equal 0, calls
  end

  private

  def build_host(normalize: nil, accepted_response: nil, error_response: nil, **options, &perform)
    Class.new(LittleGhost::Hosting::AgentCoreRuntime) do
      define_method(:normalize) do |payload, environment:|
        normalize ? normalize.call(payload, environment) : super(payload, environment:)
      end

      define_method(:perform) do |invocation, environment:|
        perform.call(invocation, environment)
      end

      define_method(:accepted_response) do |invocation|
        accepted_response ? accepted_response.call(invocation) : super(invocation)
      end

      define_method(:error_response) do |status:, message:, error: nil|
        error_response ? error_response.call(status:, message:, error:) : super(status:, message:, error:)
      end
    end.new(**options)
  end

  def environment(method, path, body = {})
    {"REQUEST_METHOD" => method, "PATH_INFO" => path, "rack.input" => StringIO.new(JSON.generate(body))}
  end
end
