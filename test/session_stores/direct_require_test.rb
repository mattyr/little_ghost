# frozen_string_literal: true

require "open3"
require "rbconfig"
require "test_helper"

class SessionStoreDirectRequireTest < Minitest::Test
  def test_stores_can_be_required_without_loading_little_ghost
    %w[filesystem memory agent_core_memory].each do |store|
      output, status = Open3.capture2e(
        RbConfig.ruby,
        "-I#{File.expand_path("../../lib", __dir__)}",
        "-e",
        "require \"little_ghost/session_stores/#{store}\""
      )

      assert status.success?, output
    end
  end
end
