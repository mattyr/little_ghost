# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"
require_relative "host"

module LittleGhost
  module CodeMode
    module Ruby
      class Session < CodeMode::Session # :nodoc:
        def initialize(broker:, sandbox_factory:, subprocess_policy:, limits:)
          @broker = broker
          @sandbox_factory = sandbox_factory
          @subprocess_policy = subprocess_policy
          @limits = limits
          @session = nil
          @workspace = nil
          @sandbox = nil
          @output = +""
          @closed = false
          @cells = 0
          @call_mutex = Mutex.new
          @call_threads = []
        end

        def execute(source:, catalog:, frame: nil, yield_time_ms: nil, max_output_tokens: nil, context: nil)
          raise ToolError, "code-mode session is closed" if @closed
          raise ToolError, "a code-mode cell is already active" if @session&.alive?
          @cells += 1
          raise ToolError, "code-mode cell limit exceeded" if @cells > @limits.fetch(:cells)
          source = String(source)
          raise ToolError, "code-mode source exceeds the limit" if source.bytesize > @limits.fetch(:source_bytes)
          normalized_catalog = Catalog.new(catalog).host_definitions

          open_process
          @session.write(Protocol.dump(
            source:,
            catalog: normalized_catalog,
            frame:,
            tool_calls: @limits.fetch(:tool_calls),
            concurrency: @limits.fetch(:concurrency)
          ))
          @explicit_yield = false
          drive(yield_time_ms:, max_output_tokens:, context:)
        end

        def wait(yield_time_ms: nil, max_output_tokens: nil, terminate: false, context: nil)
          raise ToolError, "there is no yielded code-mode cell" unless @session
          if terminate
            result = CellResult.new(output: bounded_output(max_output_tokens), status: :terminated)
            termination_error = nil
            begin
              @session.terminate
            rescue => error
              termination_error = error
            ensure
              begin
                close_process
              rescue => error
                termination_error ||= error
              end
            end
            raise termination_error if termination_error

            return result
          end

          if @explicit_yield
            @session.write(Protocol.dump(type: "resume"))
            @explicit_yield = false
          end
          drive(yield_time_ms:, max_output_tokens:, context:)
        end

        def close
          return if @closed

          @closed = true
          close_process
        end

        private

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
          @session = @sandbox.start_program(
            [RbConfig.ruby, "-e", Host::SOURCE],
            output_bytes: @limits.fetch(:output_bytes),
            memory_bytes: @limits.fetch(:memory_bytes),
            cpu_seconds: @limits.fetch(:cpu_seconds),
            file_bytes: @limits.fetch(:file_bytes),
            processes: @limits.fetch(:processes),
            allow_subprocesses: @subprocess_policy.call(@sandbox)
          )
          @deadline = monotonic_time + @limits.fetch(:wall_seconds)
          @output = +""
          @buffer = +""
        rescue
          close_process
          raise
        end

        def drive(yield_time_ms:, max_output_tokens:, context: nil)
          slice_deadline = yield_time_ms && monotonic_time + Float(yield_time_ms) / 1_000
          loop do
            context&.check!
            raise ToolError, "code-mode cell timed out" if monotonic_time >= @deadline
            if slice_deadline && monotonic_time >= slice_deadline
              return CellResult.new(output: @output.dup, status: :running, continuation: self)
            end

            read_timeout = 0.05
            read_timeout = (slice_deadline - monotonic_time).clamp(0, read_timeout) if slice_deadline
            chunk = @session.read(timeout: read_timeout)
            unless chunk.stderr.empty?
              @output << chunk.stderr
              enforce_output!(max_output_tokens)
            end
            @buffer << chunk.stdout
            while (message = Protocol.extract!(@buffer))
              begin
                case message.fetch("type")
                when "call" then dispatch_call(message)
                when "text"
                  @output << message.fetch("value")
                  enforce_output!(max_output_tokens)
                when "yield"
                  @explicit_yield = true
                  return CellResult.new(output: @output.dup, status: :yielded, continuation: self)
                when "done"
                  result = CellResult.new(output: @output.dup, value: message["value"])
                  close_process
                  return result
                when "error"
                  result = CellResult.new(output: @output.dup, status: :error, error: message.fetch("error"))
                  close_process
                  return result
                else
                  raise ProtocolError, "unknown code-mode frame"
                end
              rescue Protocol::Error, KeyError
                raise ProtocolError, "malformed code-mode frame"
              end
            end
            if chunk.eof
              detail = [@output, @buffer].reject(&:empty?).join(" ")
              close_process
              raise ProtocolError, ["code-mode process exited without a final frame", detail].reject(&:empty?).join(": ")
            end
          end
        rescue Protocol::Error => error
          close_process
          raise ProtocolError, error.message
        rescue
          close_process
          raise
        end

        def answer_call(message)
          result = @broker.call(message.fetch("name"), message.fetch("arguments"), id: message.fetch("id"))
          @session.write(Protocol.dump(type: "result", id: result.id, value: result.value, error: result.error))
        end

        def dispatch_call(message)
          thread = @call_mutex.synchronize do
            active = @call_threads.count(&:alive?)
            raise ProtocolError, "code-mode concurrent tool call limit exceeded" if active >= @limits.fetch(:concurrency)

            Thread.new { answer_call(message) }
          end
          thread.report_on_exception = false
          @call_mutex.synchronize { @call_threads << thread }
        end

        def enforce_output!(max_output_tokens = nil)
          maximum = @limits.fetch(:output_bytes)
          maximum = [maximum, Integer(max_output_tokens) * 4].min if max_output_tokens
          raise ToolError, "code-mode output exceeded the limit" if @output.bytesize > maximum
        end

        def bounded_output(max_output_tokens)
          return @output.dup unless max_output_tokens

          Support::OutputTruncation.truncate_middle_with_token_budget(@output, max_output_tokens).first
        end

        def close_process
          threads = @call_mutex.synchronize do
            current = @call_threads
            @call_threads = []
            current
          end
          session, sandbox, workspace, directory = @session, @sandbox, @workspace, @workspace_directory
          @session = @sandbox = @workspace = @workspace_directory = nil
          first_error = nil
          begin
            session&.close
          rescue => error
            first_error ||= error
          end
          deadline = monotonic_time + @limits.fetch(:cleanup_seconds)
          threads.each do |thread|
            remaining = deadline - monotonic_time
            break unless remaining.positive?

            begin
              thread.join(remaining)
            rescue => error
              first_error ||= error
            end
          end
          if threads.any?(&:alive?)
            first_error ||= CleanupError.new("Code-mode nested tool cleanup timed out")
          end
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
          raise first_error if first_error
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
