# frozen_string_literal: true

require "pathname"
require "socket"
require "uri"

CONTENT_TYPES = {
  ".css" => "text/css; charset=utf-8",
  ".html" => "text/html; charset=utf-8",
  ".js" => "text/javascript; charset=utf-8",
  ".json" => "application/json; charset=utf-8",
  ".png" => "image/png",
  ".svg" => "image/svg+xml; charset=utf-8",
  ".txt" => "text/plain; charset=utf-8"
}.freeze

root = Pathname(ARGV.fetch(0, "_site")).expand_path
port = Integer(ARGV.fetch(1, "4000"), 10)
server = TCPServer.new("127.0.0.1", port)

puts "Serving #{root} at http://127.0.0.1:#{port}/"

Signal.trap("INT") do
  exit
end

loop do
  socket = server.accept

  Thread.new(socket) do |client|
    request_line = client.gets
    next unless request_line

    method, request_target = request_line.split(" ", 3)
    while (header = client.gets)
      break if header == "\r\n"
    end

    uri = URI.parse(request_target)
    relative_path = URI.decode_www_form_component(uri.path).delete_prefix("/")
    relative_path = "index.html" if relative_path.empty?
    requested = root.join(relative_path).cleanpath
    requested = requested.join("index.html") if requested.directory?
    inside_root = requested == root || requested.to_s.start_with?("#{root}#{File::SEPARATOR}")

    if !%w[GET HEAD].include?(method)
      status = "405 Method Not Allowed"
      body = "Method not allowed"
      content_type = CONTENT_TYPES.fetch(".txt")
    elsif !inside_root || !requested.file?
      status = "404 Not Found"
      body = root.join("404.html").binread
      content_type = CONTENT_TYPES.fetch(".html")
    else
      status = "200 OK"
      body = requested.binread
      content_type = CONTENT_TYPES.fetch(requested.extname.downcase, "application/octet-stream")
    end

    client.write "HTTP/1.1 #{status}\r\n"
    client.write "Content-Type: #{content_type}\r\n"
    client.write "Content-Length: #{body.bytesize}\r\n"
    client.write "Connection: close\r\n\r\n"
    client.write body unless method == "HEAD"
  rescue URI::InvalidURIError
    client.write "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  ensure
    client.close
  end
rescue Errno::EBADF, IOError
  break
end
