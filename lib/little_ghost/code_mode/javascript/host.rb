# frozen_string_literal: true

require "mini_racer"
require "securerandom"
require_relative "../protocol"

module LittleGhost
  module CodeMode
    module Javascript
    end

    module Javascript::Host
      MAX_ACTIVE_CELLS = 8
      MAX_SOURCE_BYTES = 1024 * 1024
      CONTEXT_MEMORY_BYTES = 64 * 1024 * 1024
      JAVASCRIPT_TIMEOUT_MS = 10_000
      MAX_PENDING_TOOL_CALLS = 1_024
      Terminated = Class.new(StandardError)

      BOOTSTRAP = <<~'JAVASCRIPT'
        const __LITTLE_GHOST_CONTROL_IDENTIFIER__ = (() => {
          "use strict";
          const definitions = __LITTLE_GHOST_TOOL_DEFINITIONS__;
          const definitionIndex = Object.fromEntries(definitions.map((definition) => [definition.name, definition]));
          const calls = [];
          const outputs = [];
          const yields = [];
          const pending = new Map();
          const exitSignal = Object.freeze({exit: true});
          let nextCallId = 0;
          let done = false;
          let failure = null;

          const stringify = (value) => {
            if (typeof value === "string") return value;
            if (value === undefined) return "undefined";
            if (typeof value === "bigint") return value.toString();
            const encoded = JSON.stringify(value);
            return encoded === undefined ? String(value) : encoded;
          };

          const enqueue = (name, args) => new Promise((resolve, reject) => {
            if (!Object.prototype.hasOwnProperty.call(definitionIndex, name)) {
              reject(new Error(`Unknown tool: ${name}`));
              return;
            }
            const id = String(++nextCallId);
            pending.set(id, {resolve, reject});
            calls.push({call_id: id, name, arguments: args === undefined ? {} : args});
          });

          const tools = new Proxy(Object.freeze(Object.create(null)), {
            get(_target, property) {
              if (property === "then") return undefined;
              if (typeof property !== "string") return undefined;
              return (args = {}) => enqueue(property, args);
            }
          });
          const catalog = definitions.map(({name, description}) => Object.freeze({name, description}));

          const text = (value) => { outputs.push(stringify(value)); };
          const yieldControl = () => new Promise((resolve) => {
            const id = String(++nextCallId);
            pending.set(id, {resolve, reject: resolve});
            yields.push(id);
          });
          const exit = () => { throw exitSignal; };
          const errorText = (error) => {
            if (error && typeof error.stack === "string") return error.stack;
            if (error && typeof error.message === "string") return error.message;
            return stringify(error);
          };

          Object.defineProperties(globalThis, {
            tools: {value: tools, writable: false, configurable: false},
            ALL_TOOLS: {value: Object.freeze(catalog), writable: false, configurable: false},
            text: {value: text, writable: false, configurable: false},
            yield_control: {value: yieldControl, writable: false, configurable: false},
            exit: {value: exit, writable: false, configurable: false},
            console: {value: undefined, writable: false, configurable: false},
            process: {value: undefined, writable: false, configurable: false},
            require: {value: undefined, writable: false, configurable: false},
            fetch: {value: undefined, writable: false, configurable: false},
            WebAssembly: {value: undefined, writable: false, configurable: false},
            ArrayBuffer: {value: undefined, writable: false, configurable: false},
            SharedArrayBuffer: {value: undefined, writable: false, configurable: false},
            DataView: {value: undefined, writable: false, configurable: false},
            Atomics: {value: undefined, writable: false, configurable: false},
            Int8Array: {value: undefined, writable: false, configurable: false},
            Uint8Array: {value: undefined, writable: false, configurable: false},
            Uint8ClampedArray: {value: undefined, writable: false, configurable: false},
            Int16Array: {value: undefined, writable: false, configurable: false},
            Uint16Array: {value: undefined, writable: false, configurable: false},
            Int32Array: {value: undefined, writable: false, configurable: false},
            Uint32Array: {value: undefined, writable: false, configurable: false},
            BigInt64Array: {value: undefined, writable: false, configurable: false},
            BigUint64Array: {value: undefined, writable: false, configurable: false},
            Float32Array: {value: undefined, writable: false, configurable: false},
            Float64Array: {value: undefined, writable: false, configurable: false}
          });

          return Object.freeze({
            drain: () => ({
              calls: calls.splice(0),
              outputs: outputs.splice(0),
              yields: yields.splice(0),
              done,
              failure
            }),
            resolve: (id, ok, value) => {
              const continuation = pending.get(String(id));
              if (!continuation) return false;
              pending.delete(String(id));
              if (ok) continuation.resolve(value);
              else continuation.reject(new Error(String(value)));
              return true;
            },
            run: (source) => {
              let execution;
              try {
                execution = (0, eval)(`(async () => {\n${source}\n})()`);
              } catch (error) {
                done = true;
                failure = errorText(error);
                return;
              }
              Promise.resolve(execution).then(
                () => { done = true; },
                (error) => {
                  done = true;
                  failure = error === exitSignal ? null : errorText(error);
                }
              );
            },
          });
        })();
      JAVASCRIPT

      class Cell
        def initialize(id:, source:, tools:, writer:, finished:)
          @id = id
          @source = source
          @tools = tools
          @writer = writer
          @finished = finished
          @incoming = Queue.new
          @context_mutex = Mutex.new
          @context = nil
          @control_identifier = "__littleGhost_control_#{SecureRandom.hex(32)}"
          @terminating = false
          @thread = Thread.new { run }
          @thread.report_on_exception = false
        end

        def deliver(message)
          @incoming << message
        end

        def terminate
          @incoming << {"type" => "terminate"}
          @context_mutex.synchronize do
            @terminating = true
            @context&.stop
          end
        rescue MiniRacer::ContextDisposedError
          nil
        end

        def join(timeout = nil)
          @thread.join(timeout)
        end

        private

        def run
          context = MiniRacer::Context.new(
            max_memory: CONTEXT_MEMORY_BYTES,
            timeout: JAVASCRIPT_TIMEOUT_MS
          )
          @context_mutex.synchronize { @context = context }
          definitions = JSON.generate(@tools)
          context.eval(
            BOOTSTRAP
              .gsub("__LITTLE_GHOST_CONTROL_IDENTIFIER__", @control_identifier)
              .sub("__LITTLE_GHOST_TOOL_DEFINITIONS__", definitions),
            filename: "little-ghost-code-mode-bootstrap.js"
          )
          call_control(context, :run, @source)
          pump(context)
        rescue Terminated
          emit(type: "terminated")
        rescue MiniRacer::ScriptTerminatedError
          if @context_mutex.synchronize { @terminating }
            emit(type: "terminated")
          else
            emit(type: "failed", error: "JavaScript execution exceeded its limit", fatal: true)
          end
        rescue MiniRacer::V8OutOfMemoryError
          emit(type: "failed", error: "JavaScript execution exceeded its memory limit", fatal: true)
        rescue => error
          emit(type: "failed", error: "#{error.class}: #{error.message}", fatal: true)
        ensure
          @context_mutex.synchronize do
            @context&.dispose
            @context = nil
          rescue MiniRacer::ContextDisposedError
            @context = nil
          end
          @finished.call(@id)
        end

        def pump(context)
          loop do
            state = call_control(context, :drain)
            Array(state["outputs"]).each { |value| emit(type: "output", value:) }
            calls = Array(state["calls"])
            if calls.length > MAX_PENDING_TOOL_CALLS
              emit(type: "failed", error: "Code-mode cell exceeded the pending tool-call limit", fatal: true)
              return
            end
            emit(type: "tool_calls", calls:) unless calls.empty?
            yield_ids = Array(state["yields"])
            emit(type: "yield") unless yield_ids.empty?
            unless calls.empty? && yield_ids.empty?
              wait_for_results(context, calls.length, resume: !yield_ids.empty?)
              yield_ids.each { |id| call_control(context, :resolve, id, true, nil) }
              next
            end

            if state["done"]
              if state["failure"]
                emit(type: "failed", error: state["failure"])
              else
                emit(type: "complete")
              end
              return
            end

            wait_for_results(context, 0)
          end
        end

        def wait_for_results(context, expected, resume: false)
          delivered = 0
          resumed = !resume
          loop do
            message = @incoming.pop(timeout: 0.05)
            next unless message
            return terminate_cell if message["type"] == "terminate"

            if message["type"] == "resume"
              resumed = true
              break if delivered >= expected
              next
            end

            call_control(
              context, :resolve, message.fetch("call_id"), message.fetch("ok"),
              message["ok"] ? message["value"] : message["error"]
            )
            delivered += 1
            break if delivered >= expected && resumed
          end
        end

        def terminate_cell
          raise Terminated
        end

        def call_control(context, method, *arguments)
          encoded_arguments = arguments.map { |argument| JSON.generate(argument) }.join(",")
          context.eval("#{@control_identifier}.#{method}(#{encoded_arguments})")
        end

        def emit(type:, **attributes)
          @writer.call(type:, cell_id: @id, **attributes)
        end
      end

      class Runner
        def initialize(input: $stdin, output: $stdout)
          @input = input
          @output = output
          @cells = {}
          @cells_mutex = Mutex.new
          @writer_mutex = Mutex.new
        end

        def run
          while (message = Protocol.read(@input))
            receive(message)
          end
        ensure
          cells = @cells_mutex.synchronize { @cells.values.dup }
          cells.each(&:terminate)
          cells.each { |cell| cell.join(0.5) }
        end

        private

        def receive(message)
          case message["type"]
          when "execute" then execute(message)
          when "tool_result" then cell(message.fetch("cell_id"))&.deliver(message)
          when "resume" then cell(message.fetch("cell_id"))&.deliver(message)
          when "terminate" then cell(message.fetch("cell_id"))&.terminate
          else raise Protocol::Error, "Unknown code-mode host request"
          end
        end

        def execute(message)
          id = message.fetch("cell_id").to_s
          source = message.fetch("source").to_s
          tools = message.fetch("tools")
          raise Protocol::Error, "Code-mode source exceeds the size limit" if source.bytesize > MAX_SOURCE_BYTES
          raise Protocol::Error, "Code-mode tools must be an array" unless tools.is_a?(Array)

          created = @cells_mutex.synchronize do
            next false if @cells.key?(id) || @cells.length >= MAX_ACTIVE_CELLS

            @cells[id] = Cell.new(
              id:, source:, tools:, writer: method(:write),
              finished: ->(cell_id) { @cells_mutex.synchronize { @cells.delete(cell_id) } }
            )
            true
          end
          unless created
            write(type: "failed", cell_id: id, error: "Code-mode host has too many active cells", fatal: true)
          end
        rescue KeyError, TypeError, Protocol::Error => error
          write(type: "failed", cell_id: id.to_s, error: "Invalid code-mode request: #{error.message}", fatal: true)
        end

        def cell(id)
          @cells_mutex.synchronize { @cells[id.to_s] }
        end

        def write(message)
          @writer_mutex.synchronize { Protocol.write(@output, message) }
        end
      end

      module_function

      def run
        MiniRacer::Platform.set_flags!(:jitless)
        Runner.new.run
      end
    end
  end
end
