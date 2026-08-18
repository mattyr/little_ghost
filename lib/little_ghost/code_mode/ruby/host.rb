# frozen_string_literal: true

module LittleGhost
  module CodeMode
    module Ruby
      module Host # :nodoc:
        SOURCE = <<~'RUBY'
            require "json"
            STDOUT.sync = true
            begin
            read_exactly = lambda do |length|
              value = +"".b
              value << (STDIN.read(length - value.bytesize) || raise("incomplete protocol frame")) while value.bytesize < length
              value
            end
            read_frame = lambda do
              length = read_exactly.call(4).unpack1("N")
              raise "protocol frame too large" if length > 64 * 1024 * 1024
              JSON.parse(read_exactly.call(length))
            end
            write_frame = lambda do |value|
              payload = JSON.generate(value)
              raise "protocol frame too large" if payload.bytesize > 64 * 1024 * 1024
              STDOUT.write([payload.bytesize].pack("N"))
              STDOUT.write(payload)
              STDOUT.flush
            end
            request = read_frame.call
            catalog = request.fetch("catalog")
            write_lock = Mutex.new
            queues_lock = Mutex.new
            response_queues = {}
            resume_queue = Queue.new
            calls = 0
            max_calls = request.fetch("tool_calls")
            emit = ->(value) { write_lock.synchronize { write_frame.call(value) } }
            reader = Thread.new do
              loop do
                response = read_frame.call
                if response["type"] == "resume"
                  resume_queue << response
                elsif response["id"]
                  queue = queues_lock.synchronize { response_queues[response["id"]] }
                  queue << response if queue
                end
              end
            end
            invoke = lambda do |name, arguments|
              id, queue = queues_lock.synchronize do
                calls += 1
                raise "tool call limit exceeded" if calls > max_calls
                id = "call-#{calls}"
                queue = Queue.new
                response_queues[id] = queue
                [id, queue]
              end
              write_lock.synchronize do
                write_frame.call(type: "call", id: id, name: name, arguments: arguments)
              end
              response = queue.pop
              queues_lock.synchronize { response_queues.delete(id) }
              raise response.fetch("error") if response["error"]
              response["value"]
            end
            tools = Object.new
            tools.define_singleton_method(:call) { |name, arguments = {}| invoke.call(name.to_s, arguments) }
            catalog.each do |specification|
              name = specification.fetch("name")
              method_name = name.gsub(/[^a-zA-Z0-9_]/, "_").sub(/\A(?=\d)/, "tool_")
              tools.define_singleton_method(method_name) { |**arguments| invoke.call(name, arguments) }
            end
            concurrency = request.fetch("concurrency")
            tools.define_singleton_method(:parallel) do |*operations|
              raise ArgumentError, "parallel accepts callables" unless operations.all? { |operation| operation.respond_to?(:call) }
              operations.each_slice(concurrency).flat_map do |batch|
                batch.map { |operation| Thread.new { operation.call } }.map(&:value)
              end
            end
            Object.const_set(:ALL_TOOLS, catalog.freeze) unless Object.const_defined?(:ALL_TOOLS)
            Object.const_set(:FRAME, request["frame"].freeze) if request["frame"] && !Object.const_defined?(:FRAME)
            context = Object.new
            finished = false
            finish_value = nil
            context.define_singleton_method(:tools) { tools }
            context.define_singleton_method(:text) { |value| emit.call(type: "text", value: value.to_s); nil }
            context.define_singleton_method(:yield_control) do
              emit.call(type: "yield")
              response = resume_queue.pop
              raise "invalid resume frame" unless response["type"] == "resume"
              nil
            end
            context.define_singleton_method(:finish) do |value = nil|
              finished = true
              finish_value = value
              throw :little_ghost_finish
            end
            value = catch(:little_ghost_finish) { context.instance_eval(request.fetch("source"), "(code-mode)", 1) }
            value = finish_value if finished
            emit.call(type: "done", value: value)
          rescue Exception => error
            STDERR.puts("#{error.class}: #{error.message}")
            write_frame&.call(type: "error", error: "#{error.class}: #{error.message}")
            exit 1
            end
        RUBY
      end
    end
  end
end
