# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"
require_relative "host"

module LittleGhost
  module CodeMode
    module Ruby # :nodoc:
      class Session < CodeMode::Session # :nodoc:
        OBSERVATION_SECONDS = 60

        def initialize(broker:, sandbox_factory:, subprocess_policy:, limits:, observation_seconds: OBSERVATION_SECONDS,
          task_runner: nil)
          @broker = broker
          @task_runner = task_runner || broker.task_runner
          @sandbox_factory = sandbox_factory
          @subprocess_policy = subprocess_policy
          @limits = limits
          @observation_seconds = Float(observation_seconds)
          raise ArgumentError, "observation_seconds must be positive" unless @observation_seconds.positive?
          @session = nil
          @workspace = nil
          @sandbox = nil
          @deferred_cleanup = nil
          @output = +""
          @closed = false
          @close_complete = false
          @control_mutex = Mutex.new
          @programs = 0
          @call_mutex = Mutex.new
          @call_condition = ConditionVariable.new
          @call_tasks = []
          @call_spawns = 0
          @call_errors = []
          @closing_marker = {closing: false}
          @lifecycle_mutex = Mutex.new
          @lifecycle_condition = ConditionVariable.new
          @generation = nil
          @expiring_generation = nil
          @pending_program_error = nil
          @watchdog = nil
          @watchdog_mutex = Mutex.new
          @watchdog_condition = ConditionVariable.new
          @watchdog_generation = nil
        end

        def execute(source:, catalog:, frame: nil, max_output_tokens: nil, context: nil)
          with_control do
            execute_program(source:, catalog:, frame:, max_output_tokens:, context:)
          end
        end

        def wait(max_output_tokens: nil, context: nil)
          with_control { wait_for_program(max_output_tokens:, context:) }
        end

        def stop(max_output_tokens: nil, context: nil)
          with_control { stop_program(max_output_tokens:, context:) }
        end

        def close
          acquired = false
          return if @close_complete

          @closed = true
          acquired = @control_mutex.try_lock
          unless acquired
            raise ToolError, "cannot close while another code-mode control operation is active"
          end
          cleanup_error = begin
            close_process
            nil
          rescue => error
            error
          end
          pending_error = begin
            raise_program_cleanup_error!
            nil
          rescue => error
            error
          end
          @close_complete = true unless cleanup_error || pending_error
          raise(cleanup_error || pending_error) if cleanup_error || pending_error
        ensure
          @control_mutex.unlock if acquired
        end

        private

        def execute_program(source:, catalog:, frame:, max_output_tokens:, context:)
          raise ToolError, "code-mode session is closed" if @closed
          ensure_program_can_start!
          @programs += 1
          raise ToolError, "code-mode program limit exceeded" if @programs > @limits.fetch(:programs)
          source = String(source)
          raise ToolError, "code-mode source exceeds the limit" if source.bytesize > @limits.fetch(:source_bytes)
          normalized_catalog = Catalog.new(catalog).host_definitions

          generation, process = open_process
          process_opened = true
          process.write(Protocol.dump(
            source:,
            catalog: normalized_catalog,
            frame:,
            tool_calls: @limits.fetch(:tool_calls),
            concurrency: @limits.fetch(:concurrency)
          ))
          drive(generation:, process:, max_output_tokens:, context:)
        rescue
          close_process(generation:) if process_opened
          raise
        end

        def wait_for_program(max_output_tokens:, context:)
          generation, process = active_process
          drive(generation:, process:, max_output_tokens:, context:)
        rescue
          close_process(generation:) if generation
          raise
        end

        def stop_program(max_output_tokens:, context:)
          context&.check!
          generation, process = active_process
          mark_process_closing
          termination_error = nil
          begin
            process.terminate
            collect_remaining_output(process)
          rescue => error
            termination_error = error
          ensure
            begin
              close_process(generation:)
            rescue => error
              termination_error ||= error
            end
          end
          raise termination_error if termination_error

          ProgramResult.new(output: drain_output(max_output_tokens), status: :terminated)
        end

        def with_control
          acquired = @control_mutex.try_lock
          unless acquired
            raise ToolError, "another code-mode control operation is already active"
          end

          yield
        ensure
          @control_mutex.unlock if acquired
        end

        def ensure_program_can_start!
          error = @lifecycle_mutex.synchronize do
            @lifecycle_condition.wait(@lifecycle_mutex) while @expiring_generation
            pending = take_pending_program_error
            raise ToolError, "a code-mode program is already active" if !pending && (@generation || @session)

            pending
          end
          raise error if error
        end

        def open_process
          @workspace_directory = Dir.mktmpdir("little-ghost-code-mode-")
          @workspace = Workspace.new(root: @workspace_directory).open
          factory = @sandbox_factory || lambda do |workspace:, required_runtime_paths:|
            Sandboxes::Native.new(
              workspace:,
              policy: {files: {root: :read_write}, network: :none}
            )
          end
          @sandbox = if factory.respond_to?(:call)
            factory.call(workspace: @workspace, required_runtime_paths: {})
          else
            factory.new(workspace: @workspace)
          end
          @sandbox.open
          raise ToolError, "code-mode session is closed" if @closed
          @session = @sandbox.start_program(
            [RbConfig.ruby, "-e", Host::SOURCE],
            output_bytes: @limits.fetch(:output_bytes),
            memory_bytes: @limits.fetch(:memory_bytes),
            cpu_seconds: @limits.fetch(:cpu_seconds),
            file_bytes: @limits.fetch(:file_bytes),
            allow_subprocesses: @subprocess_policy.call(@sandbox)
          )
          generation = Object.new
          @deadline = monotonic_time + @limits.fetch(:wall_seconds)
          @output = +""
          @output_bytes = 0
          @buffer = +""
          @lifecycle_mutex.synchronize { @generation = generation }
          start_watchdog(generation, @deadline)
          [generation, @session]
        rescue
          close_process
          raise
        end

        def drive(generation:, process:, max_output_tokens:, context: nil)
          slice_deadline = monotonic_time + @observation_seconds
          loop do
            context&.check!
            raise_call_error!
            expire_program(generation) if monotonic_time >= @deadline
            raise_program_error!(generation)
            if monotonic_time >= slice_deadline
              return ProgramResult.new(output: drain_output(max_output_tokens), status: :still_working)
            end

            read_timeout = 0.05
            read_timeout = (slice_deadline - monotonic_time).clamp(0, read_timeout)
            chunk = process.read(timeout: read_timeout)
            raise_call_error!
            unless chunk.stderr.empty?
              append_output(chunk.stderr)
            end
            @buffer << chunk.stdout
            while (message = Protocol.extract!(@buffer))
              begin
                case message.fetch("type")
                when "call" then dispatch_call(message, process)
                when "text"
                  append_output(message.fetch("value"))
                when "done"
                  raise_program_error!(generation)
                  result = ProgramResult.new(output: drain_output(max_output_tokens), value: message["value"])
                  close_process(generation:)
                  return result
                when "error"
                  raise_program_error!(generation)
                  result = ProgramResult.new(
                    output: drain_output(max_output_tokens), status: :error, error: message.fetch("error")
                  )
                  close_process(generation:)
                  return result
                else
                  raise ProtocolError, "unknown code-mode frame"
                end
              rescue Protocol::Error, KeyError
                raise ProtocolError, "malformed code-mode frame"
              end
            end
            if chunk.eof
              raise_program_error!(generation)
              detail = [@output, @buffer].reject(&:empty?).join(" ")
              close_process(generation:)
              raise ProtocolError, ["code-mode process exited without a final frame", detail].reject(&:empty?).join(": ")
            end
          end
        rescue Protocol::Error => error
          close_process(generation:)
          raise ProtocolError, error.message
        rescue
          close_process(generation:)
          raise
        end

        def answer_call(message, process, closing_marker)
          result = @broker.call(message.fetch("name"), message.fetch("arguments"), id: message.fetch("id"))
          frame = Protocol.dump(type: "result", id: result.id, value: result.value, error: result.error)
          begin
            process.write(frame)
          rescue IOError, SystemCallError
            raise unless @call_mutex.synchronize { closing_marker.fetch(:closing) }
          end
        end

        def dispatch_call(message, process)
          call_errors, closing_marker = @call_mutex.synchronize do
            active = @call_tasks.count(&:alive?)
            raise ProtocolError, "code-mode concurrent tool call limit exceeded" if active >= @limits.fetch(:concurrency)

            @call_spawns += 1
            [@call_errors, @closing_marker]
          end
          task = @task_runner.spawn do
            answer_call(message, process, closing_marker)
          rescue => error
            @call_mutex.synchronize { call_errors << error }
          end
          @call_mutex.synchronize { @call_tasks << task }
        ensure
          if call_errors
            @call_mutex.synchronize do
              @call_spawns -= 1
              @call_condition.broadcast
            end
          end
        end

        def append_output(value)
          value = String(value).dup.force_encoding(Encoding::UTF_8).scrub
          @output_bytes += value.bytesize
          raise ToolError, "code-mode output exceeded the limit" if @output_bytes > @limits.fetch(:output_bytes)

          @output << value
        end

        def collect_remaining_output(process)
          loop do
            chunk = process.read(timeout: 0)
            append_output(chunk.stderr) unless chunk.stderr.empty?
            @buffer << chunk.stdout
            while (message = Protocol.extract!(@buffer))
              append_output(message.fetch("value")) if message["type"] == "text"
            end
            break if chunk.eof || (chunk.stdout.empty? && chunk.stderr.empty?)
          end
        rescue Protocol::Error, KeyError
          raise ProtocolError, "malformed code-mode frame"
        end

        def drain_output(max_output_tokens)
          output = @output
          @output = +""
          return output unless max_output_tokens

          Support::OutputTruncation.truncate_middle_with_token_budget(output, max_output_tokens).first
        end

        def active_process
          raise_pending_program_error!
          @lifecycle_mutex.synchronize do
            @lifecycle_condition.wait(@lifecycle_mutex) while @expiring_generation
            error = take_pending_program_error
            raise error if error
            raise ToolError, "there is no active code-mode program" unless @generation && @session

            [@generation, @session]
          end
        end

        def close_process(generation: nil)
          pending_call_cleanup = @call_mutex.synchronize do
            @call_spawns.positive? || !@call_tasks.empty? || !@call_errors.empty?
          end
          claimed = @lifecycle_mutex.synchronize do
            if @deferred_cleanup
              deferred = @deferred_cleanup
              return if generation && !deferred.first.equal?(generation)

              @deferred_cleanup = nil
              deferred
            elsif !pending_call_cleanup && !@session && !@sandbox && !@workspace && !@workspace_directory
              return
            else
              target = generation || @generation
              if target
                return unless @generation.equal?(target)
              end

              values = [target, @session, @sandbox, @workspace, @workspace_directory]
              @generation = nil
              @session = @sandbox = @workspace = @workspace_directory = nil
              values
            end
          end
          target, session, sandbox, workspace, directory = claimed
          watchdog = cancel_watchdog(target)
          deadline = monotonic_time + @limits.fetch(:cleanup_seconds)
          handoff_timed_out = false
          tasks, call_errors = @call_mutex.synchronize do
            @closing_marker[:closing] = true
            while @call_spawns.positive?
              remaining = deadline - monotonic_time
              unless remaining.positive?
                handoff_timed_out = true
                break
              end

              @call_condition.wait(@call_mutex, remaining)
            end
            if handoff_timed_out
              [[], []]
            else
              current_tasks = @call_tasks
              current_errors = @call_errors
              @call_tasks = []
              @call_errors = []
              @closing_marker = {closing: false}
              [current_tasks, current_errors]
            end
          end
          if handoff_timed_out
            @closed = true
            defer_process_cleanup(claimed)
            watchdog&.wait unless watchdog&.current?
            raise CleanupError, "Code-mode nested tool cleanup timed out"
          end
          first_error = nil
          tasks.each do |task|
            remaining = deadline - monotonic_time
            break unless remaining.positive?

            begin
              task.wait(deadline: Time.now + remaining)
            rescue DeadlineExceededError
              break
            rescue => error
              first_error ||= error
            end
          end
          if tasks.any?(&:alive?)
            @closed = true
            defer_call_cleanup(tasks, call_errors)
            defer_process_cleanup(claimed)
            watchdog&.wait unless watchdog&.current?
            raise CleanupError, "Code-mode nested tool cleanup timed out"
          end
          begin
            session&.close
          rescue => error
            first_error ||= error
          end
          call_error = @call_mutex.synchronize { call_errors.shift }
          first_error ||= call_error
          begin
            sandbox&.close
          rescue => error
            first_error ||= error
          end
          begin
            workspace&.close
          rescue => error
            first_error ||= error
          end
          begin
            FileUtils.remove_entry(directory) if directory && File.exist?(directory)
          rescue => error
            first_error ||= error
          end
          watchdog&.wait unless watchdog&.current?
          raise first_error if first_error
        end

        def defer_call_cleanup(tasks, call_errors)
          @call_mutex.synchronize do
            @call_tasks.concat(tasks)
            @call_errors.concat(call_errors)
            @closing_marker[:closing] = true
          end
        end

        def defer_process_cleanup(claimed)
          @lifecycle_mutex.synchronize { @deferred_cleanup ||= claimed }
        end

        def start_watchdog(generation, deadline)
          @watchdog_mutex.synchronize do
            @watchdog_generation = generation
          end
          task = @task_runner.spawn do
            expired = @watchdog_mutex.synchronize do
              loop do
                break false unless @watchdog_generation.equal?(generation)

                remaining = deadline - monotonic_time
                break true unless remaining.positive?

                @watchdog_condition.wait(@watchdog_mutex, remaining)
              end
            end
            expire_program(generation) if expired
          rescue => error
            record_program_error(generation, error)
          end
          installed = @watchdog_mutex.synchronize do
            if @watchdog_generation.equal?(generation)
              @watchdog = task
              true
            else
              false
            end
          end
          task.wait unless installed || task.current?
        rescue
          @watchdog_mutex.synchronize do
            @watchdog_generation = nil if @watchdog_generation.equal?(generation)
          end
          raise
        end

        def cancel_watchdog(generation)
          @watchdog_mutex.synchronize do
            return unless !generation || @watchdog_generation.equal?(generation)

            task = @watchdog
            @watchdog_generation = nil
            @watchdog = nil
            @watchdog_condition.broadcast
            task
          end
        end

        def expire_program(generation)
          process = @lifecycle_mutex.synchronize do
            if @expiring_generation.equal?(generation)
              nil
            elsif @generation.equal?(generation)
              @expiring_generation = generation
              @session
            end
          end
          return unless process

          error = ToolError.new("code-mode program timed out")
          begin
            mark_process_closing
            process.terminate
          rescue => cleanup_error
            error = cleanup_error
          ensure
            begin
              close_process(generation:)
            rescue => cleanup_error
              error = cleanup_error
            end
            record_program_error(generation, error)
          end
        end

        def record_program_error(generation, error)
          @lifecycle_mutex.synchronize do
            @pending_program_error ||= [generation, error]
            @expiring_generation = nil if @expiring_generation.equal?(generation)
            @lifecycle_condition.broadcast
          end
        end

        def raise_program_error!(generation)
          error = @lifecycle_mutex.synchronize do
            @lifecycle_condition.wait(@lifecycle_mutex) while @expiring_generation.equal?(generation)
            take_pending_program_error(generation)
          end
          raise error if error
        end

        def raise_pending_program_error!
          error = @lifecycle_mutex.synchronize { take_pending_program_error }
          raise error if error
        end

        def raise_program_cleanup_error!
          error = @lifecycle_mutex.synchronize do
            @lifecycle_condition.wait(@lifecycle_mutex) while @expiring_generation
            take_pending_program_error
          end
          raise error if error
        end

        def take_pending_program_error(generation = nil)
          return unless @pending_program_error
          return if generation && !@pending_program_error.first.equal?(generation)

          @pending_program_error.tap { @pending_program_error = nil }.last
        end

        def mark_process_closing
          @call_mutex.synchronize { @closing_marker[:closing] = true }
        end

        def raise_call_error!
          error = @call_mutex.synchronize { @call_errors.shift }
          raise error if error
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
