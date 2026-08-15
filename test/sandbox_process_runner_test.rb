# frozen_string_literal: true

require "test_helper"
require "little_ghost/sandbox/process_runner"

class SandboxProcessRunnerTest < Minitest::Test
  def test_captures_exit_status_and_bounded_output
    result = LittleGhost::Sandbox::ProcessRunner.run(
      command: [Gem.ruby, "-e", '$stdout.write("a" * 20); $stderr.write("problem")'],
      timeout: 5,
      max_output_bytes: 5
    )

    assert_equal 0, result.exit_code
    assert_equal "aaaaa\n[output truncated]", result.stdout
    assert_equal "probl\n[output truncated]", result.stderr
  end

  def test_starts_with_an_empty_environment_by_default
    result = LittleGhost::Sandbox::ProcessRunner.run(
      command: [Gem.ruby, "-e", 'print ENV.fetch("VISIBLE", "missing")'],
      timeout: 5,
      environment: {"VISIBLE" => "configured"}
    )

    assert_equal "configured", result.stdout
    assert_equal 0, result.exit_code
  end

  def test_reports_a_missing_executable_as_exit_127
    result = LittleGhost::Sandbox::ProcessRunner.run(
      command: ["/little-ghost/missing-command"],
      timeout: 5
    )

    assert_equal 127, result.exit_code
    assert_includes result.stderr, "command not found"
  end

  def test_terminates_the_process_group_after_a_timeout
    error = assert_raises(LittleGhost::ToolError) do
      LittleGhost::Sandbox::ProcessRunner.run(
        command: [Gem.ruby, "-e", "sleep 30"],
        timeout: 0.05
      )
    end

    assert_includes error.message, "timed out"
  end
end
