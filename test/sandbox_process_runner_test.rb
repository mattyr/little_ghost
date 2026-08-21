# frozen_string_literal: true

require "test_helper"
require "async"
require "little_ghost/sandbox/process_runner"
require "little_ghost/sandbox/process_session"

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

  def test_termination_grace_does_not_stall_the_scheduler
    finished = false
    heartbeat_before_finish = false

    Async do |task|
      task.async do |child|
        child.sleep(0.4)
        heartbeat_before_finish = !finished
      end
      assert_raises(LittleGhost::ToolError) do
        LittleGhost::Sandbox::ProcessRunner.run(
          command: [Gem.ruby, "-e", 'trap("TERM") {}; sleep 30'],
          timeout: 0.3
        )
      end
      finished = true
    end

    assert heartbeat_before_finish
  end

  def test_process_session_enforces_parent_supervised_memory
    samples = Queue.new
    session = LittleGhost::Sandbox::ProcessSession.new(
      command: [Gem.ruby, "-e", "sleep 30"],
      memory_bytes: 1,
      memory_reader: lambda do |_pid|
        samples << true
        2
      end
    )

    error = assert_raises(LittleGhost::ToolError) { session.wait(timeout: 2) }

    assert_match(/memory exceeded/, error.message)
    assert samples.pop
    assert_empty samples
  ensure
    session&.close
  end

  def test_process_session_fails_closed_when_memory_supervision_fails
    failure = RuntimeError.new("sensitive failure detail")
    samples = Queue.new
    session = LittleGhost::Sandbox::ProcessSession.new(
      command: [Gem.ruby, "-e", "sleep 30"],
      memory_bytes: 1,
      memory_reader: lambda do |_pid|
        samples << true
        raise failure
      end
    )

    error = assert_raises(LittleGhost::ToolError) { session.wait(timeout: 2) }

    assert_match(/supervisor failed/, error.message)
    assert_includes error.message, "RuntimeError"
    refute_includes error.message, failure.message
    assert_same failure, error.cause
    assert_equal 3, samples.size
  ensure
    session&.close
  end

  def test_process_session_resets_consecutive_memory_supervision_failures_after_a_success
    failure = RuntimeError.new("unavailable")
    samples = Queue.new
    readings = [failure, failure, 0, failure, failure, failure]
    session = LittleGhost::Sandbox::ProcessSession.new(
      command: [Gem.ruby, "-e", "sleep 30"],
      memory_bytes: 1,
      memory_reader: lambda do |_pid|
        reading = readings.shift
        samples << reading
        raise reading if reading.is_a?(Exception)

        reading
      end
    )

    error = assert_raises(LittleGhost::ToolError) { session.wait(timeout: 2) }

    assert_match(/supervisor failed/, error.message)
    assert_equal 6, samples.size
  ensure
    session&.close
  end

  def test_linux_memory_snapshot_ignores_disappeared_unreadable_and_malformed_descendants
    session = LittleGhost::Sandbox::ProcessSession.allocate
    statuses = {
      "/proc/100/status" => "PPid:\t1\nVmRSS:\t10 kB\n",
      "/proc/104/status" => "PPid:\t100\nVmRSS:\t20 kB\n",
      "/proc/105/status" => "PPid:\t104\nVmRSS:\t30 kB\n",
      "/proc/103/status" => "Name:\tmalformed\n"
    }
    reader = lambda do |path|
      raise Errno::ENOENT, path if path.end_with?("/101/status")
      raise Errno::EACCES, path if path.end_with?("/102/status")

      statuses.fetch(path)
    end

    rss = Dir.stub(:children, %w[100 101 102 103 104 105]) do
      File.stub(:read, reader) { session.send(:linux_process_tree_rss, 100) }
    end

    assert_equal 60 * 1024, rss
  end

  def test_linux_memory_snapshot_distinguishes_a_whole_snapshot_failure
    session = LittleGhost::Sandbox::ProcessSession.allocate
    failure = Errno::EACCES.new("/proc")

    error = Dir.stub(:children, ->(_path) { raise failure }) do
      assert_raises(LittleGhost::DependencyError) { session.send(:linux_process_tree_rss, 100) }
    end

    assert_includes error.message, "snapshot /proc"
    assert_same failure, error.cause
  end

  def test_linux_memory_snapshot_distinguishes_a_root_process_failure
    session = LittleGhost::Sandbox::ProcessSession.allocate
    failure = Errno::ENOENT.new("/proc/100/status")

    error = Dir.stub(:children, ["100"]) do
      File.stub(:read, ->(_path) { raise failure }) do
        assert_raises(LittleGhost::DependencyError) { session.send(:linux_process_tree_rss, 100) }
      end
    end

    assert_includes error.message, "root process /proc/100/status"
    assert_same failure, error.cause
  end

  def test_process_session_cleans_the_group_after_its_leader_exits
    session = LittleGhost::Sandbox::ProcessSession.new(
      command: [Gem.ruby, "-e", "child = fork { sleep 30 }; puts child; STDOUT.flush; exit!"]
    )
    child_pid = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until child_pid || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      output = session.read(timeout: 0.05).stdout
      child_pid = Integer(output, exception: false) unless output.empty?
    end

    refute_nil child_pid
    assert_predicate session, :alive?
    session.terminate

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    while process_alive?(child_pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep(0.01)
    end
    refute process_alive?(child_pid)
  ensure
    session&.close
    begin
      Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
    rescue Errno::ESRCH
      nil
    end
  end

  private

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
