# frozen_string_literal: true

require "test_helper"

class LittleGhostTest < Minitest::Test
  def test_exposes_the_version
    assert_equal "0.0.1", LittleGhost::VERSION
  end
end
