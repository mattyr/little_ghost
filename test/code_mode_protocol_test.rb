# frozen_string_literal: true

require "test_helper"
require "stringio"

class CodeModeProtocolTest < Minitest::Test
  def test_frames_non_ascii_json_as_binary_at_the_one_byte_length_boundary
    base = JSON.generate("value" => "—")
    value = {"value" => "—#{"a" * (128 - base.bytesize)}"}
    payload = JSON.generate(value)

    assert_equal 128, payload.bytesize

    frame = LittleGhost::CodeMode::Protocol.dump(value)

    assert_equal Encoding::BINARY, frame.encoding
    assert_equal [128].pack("N"), frame.byteslice(0, 4)
    assert_equal value, LittleGhost::CodeMode::Protocol.read(StringIO.new(frame))
  end

  def test_extracts_non_ascii_json_from_a_binary_buffer
    value = {"message" => "Diagnostic finished — no changes made."}
    buffer = LittleGhost::CodeMode::Protocol.dump(value)

    assert_equal value, LittleGhost::CodeMode::Protocol.extract!(buffer)
    assert_empty buffer
  end
end
