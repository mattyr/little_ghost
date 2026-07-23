# frozen_string_literal: true

require "test_helper"
require "little_ghost/providers/sse_parser"

class SSEParserTest < Minitest::Test
  def test_parses_fragmented_crlf_and_multiline_events
    parser = LittleGhost::Providers::SSEParser.new

    assert_empty parser << "event: message\r\nda"
    assert_equal ["{\n\"ok\":true}"], parser << "ta: {\r\ndata: \"ok\":true}\r\n\r\n"
  end

  def test_finish_flushes_final_frame
    parser = LittleGhost::Providers::SSEParser.new
    parser << "data: [DONE]"

    assert_equal ["[DONE]"], parser.finish
    assert_empty parser.finish
  end

  def test_handles_crlf_split_across_chunks
    parser = LittleGhost::Providers::SSEParser.new

    assert_empty parser << "data: first\r"
    assert_equal ["first"], parser << "\n\r\n"
  end
end
