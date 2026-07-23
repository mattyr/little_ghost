# frozen_string_literal: true

require "test_helper"
require "openssl"
require "socket"

class HTTPTransportTest < Minitest::Test
  class FakeHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout

    def initialize(error: nil, response: nil)
      @error = error
      @response = response
    end

    def request(_request)
      raise @error if @error

      yield @response
    end
  end

  def test_requires_explicit_opt_in_for_cleartext_endpoints
    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::Providers::HTTPTransport.new(base_url: "http://localhost:1234", open_timeout: 1, read_timeout: 1)
    end

    transport = LittleGhost::Providers::HTTPTransport.new(
      base_url: "http://localhost:1234",
      open_timeout: 1,
      read_timeout: 1,
      allow_insecure_http: true
    )
    assert_instance_of LittleGhost::Providers::HTTPTransport, transport
  end

  def test_cancellation_interrupts_a_stalled_read
    token = LittleGhost::Support::CancellationToken.new
    server, socket, runner = stalled_request(cancellation_token: token)

    token.cancel

    assert runner.join(1), "stalled HTTP read did not stop after cancellation"
    assert_instance_of LittleGhost::CancelledError, runner.value
  ensure
    token&.cancel
    runner&.kill
    runner&.join
    socket&.close
    server&.close
  end

  def test_deadline_interrupts_a_stalled_read
    token = LittleGhost::Support::CancellationToken.new
    server, socket, runner = stalled_request(
      cancellation_token: token,
      deadline: Time.now + 0.05
    )

    assert runner.join(1), "stalled HTTP read did not stop at its deadline"
    assert_instance_of LittleGhost::DeadlineExceededError, runner.value
  ensure
    token&.cancel
    runner&.kill
    runner&.join
    socket&.close
    server&.close
  end

  def test_wraps_transient_network_and_protocol_failures_as_retryable_http_errors
    errors = [
      Net::WriteTimeout.new("write timed out"),
      Errno::EPIPE.new,
      OpenSSL::SSL::SSLError.new("TLS failed"),
      Net::HTTPBadResponse.new("bad framing")
    ]

    errors.each do |network_error|
      error = assert_raises(LittleGhost::Providers::HTTPError) do
        run_stream_with(http: FakeHTTP.new(error: network_error))
      end

      assert error.retryable?
      assert_includes error.message, network_error.class.name
    end
  end

  def test_does_not_wrap_provider_response_size_errors
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:read_body) { |&block| block.call("too large") }

    error = assert_raises(LittleGhost::ProtocolError) do
      run_stream_with(http: FakeHTTP.new(response:), max_response_bytes: 2)
    end

    assert_equal "Provider response exceeded 2 bytes", error.message
  end

  private

  def run_stream_with(http:, max_response_bytes: LittleGhost::Providers::HTTPTransport::DEFAULT_MAX_RESPONSE_BYTES)
    transport = LittleGhost::Providers::HTTPTransport.new(
      base_url: "https://provider.example",
      open_timeout: 1,
      read_timeout: 1,
      max_response_bytes:
    )
    token = LittleGhost::Support::CancellationToken.new

    Net::HTTP.stub(:new, http) do
      transport.stream(path: "responses", headers: {}, body: "{}", cancellation_token: token).to_a
    end
  end

  def stalled_request(cancellation_token:, deadline: nil)
    server = TCPServer.new("127.0.0.1", 0)
    transport = LittleGhost::Providers::HTTPTransport.new(
      base_url: "http://127.0.0.1:#{server.local_address.ip_port}",
      open_timeout: 1,
      read_timeout: 60,
      allow_insecure_http: true
    )
    runner = Thread.new do
      transport.stream(
        path: "responses",
        headers: {},
        body: "{}",
        cancellation_token:,
        deadline:
      ).to_a
    rescue => error
      error
    end
    runner.report_on_exception = false
    socket = server.accept
    [server, socket, runner]
  end
end
