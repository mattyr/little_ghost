# frozen_string_literal: true

require "socket"
require "timeout"
require "uri"

module LittleGhost
  module Network
    # Serves Envoy's headers-only external authorization protocol over a private
    # Unix socket. Application callbacks are trusted and execute in the host.
    class AuthorizerServer # :nodoc:
      MAX_HEADER_BYTES = 32_768
      MAX_CLIENTS = 64
      READ_TIMEOUT = 5
      SHUTDOWN_TIMEOUT = 1
      ALWAYS_REMOVE = %w[authorization proxy-authorization cookie x-forwarded-for x-forwarded-host x-forwarded-proto].freeze

      def initialize(socket_path:, authorizer:, run: nil)
        @socket_path = socket_path
        @authorizer = authorizer
        @run = run
        @mutex = Mutex.new
        @clients = []
        @workers = []
        @stopping = false
      end

      attr_reader :socket_path

      def start
        File.unlink(socket_path) if File.exist?(socket_path)
        @server = UNIXServer.new(socket_path)
        File.chmod(0o600, socket_path)
        @thread = Thread.new { serve }
        self
      end

      def close
        @stopping = true
        @server&.close unless @server&.closed?
        clients, workers = @mutex.synchronize { [@clients.dup, @workers.dup] }
        clients.each { |client| client.close unless client.closed? }
        workers.each do |worker|
          next if worker.join(SHUTDOWN_TIMEOUT)

          worker.kill
          worker.join
        end
        @thread&.join unless @thread == Thread.current
        File.unlink(socket_path) if File.exist?(socket_path)
        nil
      end

      private

      def serve
        loop do
          client = @server.accept
          accepted = @mutex.synchronize do
            next false if @clients.length >= MAX_CLIENTS

            @clients << client
            true
          end
          unless accepted
            client.close
            next
          end
          worker = Thread.new(client) { |connection| handle(connection) }
          @mutex.synchronize { @workers << worker }
        rescue IOError, Errno::EBADF
          break if @stopping
          raise
        end
      end

      def handle(client)
        method, path, headers = read_request(client)
        host, port = authority(headers.fetch("host", ""))
        request = Request.new(
          method:,
          scheme: "https",
          host:,
          port:,
          path:,
          headers:
        )
        decision = call_authorizer(request)
        raise TypeError, "network authorizer must return LittleGhost::Network::Decision" unless decision.is_a?(Decision)

        write_response(client, decision)
      rescue => error
        write_response(client, Decision.deny(status: 503, reason: error.class.name))
      ensure
        client.close unless client.closed?
        @mutex.synchronize do
          @clients.delete(client)
          @workers.delete(Thread.current)
        end
      end

      def call_authorizer(request)
        parameters = @authorizer.method(:call).parameters
        accepts_run = parameters.any? { |kind, name| kind == :keyrest || (%i[key keyreq].include?(kind) && name == :run) }
        accepts_run ? @authorizer.call(request:, run: @run) : @authorizer.call(request:)
      end

      def read_request(client)
        total = 0
        request_line = read_line(client, total)
        total += request_line.bytesize
        method, path, version = request_line.strip.split(" ", 3)
        raise ArgumentError, "invalid authorization request" unless method && path && version&.start_with?("HTTP/")

        headers = {}
        loop do
          line = read_line(client, total)
          total += line.bytesize
          break if line == "\r\n" || line == "\n"

          name, value = line.split(":", 2)
          raise ArgumentError, "invalid authorization header" unless name && value

          headers[name.strip.downcase] = value.strip
        end
        [method, path, headers]
      end

      def read_line(client, total)
        raise ArgumentError, "authorization headers are too large" if total >= MAX_HEADER_BYTES
        raise Timeout::Error, "authorization request timed out" unless IO.select([client], nil, nil, READ_TIMEOUT)

        line = client.gets("\n", MAX_HEADER_BYTES - total + 1)
        raise ArgumentError, "incomplete authorization request" unless line
        raise ArgumentError, "authorization headers are too large" if total + line.bytesize > MAX_HEADER_BYTES

        line
      end

      def authority(value)
        uri = URI("https://#{value}")
        raise ArgumentError, "invalid request authority" unless uri.host && uri.userinfo.nil?

        [uri.host.downcase, uri.port]
      rescue URI::InvalidURIError
        raise ArgumentError, "invalid request authority"
      end

      def write_response(client, decision)
        status = decision.allowed ? 200 : decision.status
        reason = {200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 429 => "Too Many Requests", 503 => "Service Unavailable"}.fetch(status, "Forbidden")
        client.write("HTTP/1.0 #{status} #{reason}\r\n")
        removals = (ALWAYS_REMOVE + decision.remove_headers).uniq
        client.write("x-envoy-auth-headers-to-remove: #{removals.join(", ")}\r\n") unless removals.empty?
        decision.set_headers.each { |name, value| client.write("#{name}: #{value}\r\n") }
        client.write("content-length: 0\r\n\r\n")
      rescue IOError, Errno::EPIPE
        nil
      end
    end
  end
end
