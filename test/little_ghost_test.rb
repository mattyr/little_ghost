# frozen_string_literal: true

require "test_helper"

class LittleGhostTest < Minitest::Test
  def test_exposes_the_version
    assert_equal "0.1.0.pre", LittleGhost::VERSION
  end

  def test_message_accepts_one_content_hash
    message = LittleGhost::Message.new(role: :user, content: {type: "text", text: "hello"})

    assert_equal "hello", message.text
  end
end
