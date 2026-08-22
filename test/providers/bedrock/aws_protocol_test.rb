# frozen_string_literal: true

require "test_helper"
require "zlib"

class BedrockAwsProtocolTest < Minitest::Test
  ErrorResponse = Struct.new(:code, :chunks) do
    def is_a?(_type) = false
    def read_body = chunks.each { |chunk| yield chunk }
  end

  class FakeHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout

    def initialize(response) = @response = response
    def request(_request) = yield @response
  end

  def test_sigv4_matches_aws_documentation_vector
    credentials = LittleGhost::Providers::Bedrock::Credentials.new(
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    )
    signer = LittleGhost::Providers::Bedrock::AwsSigV4.new(
      service: "iam",
      region: "us-east-1",
      credentials:,
      clock: -> { Time.utc(2015, 8, 30, 12, 36) }
    )
    uri = URI("https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")

    headers = signer.headers(method: :get, uri:, headers: {"content-type" => "application/x-www-form-urlencoded; charset=utf-8"}, body: "")

    assert_includes headers.fetch("authorization"), "Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request"
    assert_includes headers.fetch("authorization"), "SignedHeaders=content-type;host;x-amz-date"
    assert_match(/Signature=[0-9a-f]{64}\z/, headers.fetch("authorization"))
  end

  def test_sigv4_canonicalizes_an_encoded_model_id_for_bedrock
    signer = LittleGhost::Providers::Bedrock::AwsSigV4.new(
      service: "bedrock",
      region: "us-east-2",
      credentials: LittleGhost::Providers::Bedrock::Credentials.new(access_key_id: "key", secret_access_key: "secret")
    )
    uri = URI("https://bedrock-runtime.us-east-2.amazonaws.com/model/us.amazon.nova-2-lite-v1%3A0/converse-stream")

    assert_equal "/model/us.amazon.nova-2-lite-v1%253A0/converse-stream", signer.send(:canonical_path, uri)
  end

  def test_event_stream_decodes_fragmented_frames_and_validates_crc
    frame = event_frame({":event-type" => "messageStart", ":message-type" => "event"}, JSON.generate(role: "assistant"))
    decoder = LittleGhost::Providers::Bedrock::EventStreamDecoder.new

    assert_empty decoder << frame.byteslice(0, 9)
    events = decoder << frame.byteslice(9, frame.bytesize)
    decoder.finish

    assert_equal "messageStart", events.first.first.fetch(":event-type")
    assert_equal({"role" => "assistant"}, JSON.parse(events.first.last))
  end

  def test_event_stream_rejects_corrupt_frames
    frame = event_frame({":event-type" => "messageStop"}, "{}").dup
    frame.setbyte(15, frame.getbyte(15) ^ 0xff)

    assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::Providers::Bedrock::EventStreamDecoder.new << frame
    end
  end

  def test_event_stream_rejects_oversized_frame_from_its_prelude
    total_length = 1024
    prelude = [total_length, 0].pack("NN")
    bytes = prelude + [Zlib.crc32(prelude)].pack("N")
    decoder = LittleGhost::Providers::Bedrock::EventStreamDecoder.new(max_frame_bytes: 512)

    error = assert_raises(LittleGhost::ProtocolError) { decoder << bytes }

    assert_includes error.message, "configured limit"
  end

  def test_event_stream_rejects_oversized_headers_from_its_prelude
    total_length = 128
    headers_length = 100
    prelude = [total_length, headers_length].pack("NN")
    bytes = prelude + [Zlib.crc32(prelude)].pack("N")
    decoder = LittleGhost::Providers::Bedrock::EventStreamDecoder.new(max_headers_bytes: 64)

    error = assert_raises(LittleGhost::ProtocolError) { decoder << bytes }

    assert_includes error.message, "headers"
  end

  def test_bedrock_error_body_is_bounded_while_streaming
    credentials = LittleGhost::Providers::Bedrock::Credentials.new(access_key_id: "key", secret_access_key: "secret")
    response = ErrorResponse.new("500", ["a" * 3000, "b" * 3000])
    client = LittleGhost::Providers::Bedrock::HTTPClient.new(region: "us-east-1", credentials:)

    Net::HTTP.stub(:new, FakeHTTP.new(response)) do
      error = assert_raises(LittleGhost::Providers::HTTPError) do
        client.converse_stream(model_id: "provider.model").stream.to_a
      end

      assert_equal 4096, error.body.bytesize
    end
  end

  def test_invoke_model_applies_its_tighter_response_bound
    credentials = LittleGhost::Providers::Bedrock::Credentials.new(access_key_id: "key", secret_access_key: "secret")
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:read_body) do |&block|
      block.call("a" * 6)
      block.call("b" * 6)
    end
    client = LittleGhost::Providers::Bedrock::HTTPClient.new(region: "us-east-1", credentials:)

    Net::HTTP.stub(:new, FakeHTTP.new(response)) do
      error = assert_raises(LittleGhost::ProtocolError) do
        client.invoke_model(model_id: "provider.model", body: {}, max_response_bytes: 10)
      end

      assert_includes error.message, "exceeded 10 bytes"
    end
  end

  private

  def event_frame(headers, payload)
    encoded_headers = headers.map do |name, value|
      name = name.b
      value = value.b
      [name.bytesize].pack("C") + name + [7, value.bytesize].pack("Cn") + value
    end.join.b
    total_length = 16 + encoded_headers.bytesize + payload.bytesize
    prelude = [total_length, encoded_headers.bytesize].pack("NN")
    message = prelude + [Zlib.crc32(prelude)].pack("N") + encoded_headers + payload.b
    message + [Zlib.crc32(message)].pack("N")
  end
end
