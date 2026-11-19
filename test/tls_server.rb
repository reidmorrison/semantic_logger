require "openssl"
require "socket"

# A TLS server on 127.0.0.1, with a certificate of its own, for the tests of the appenders that connect over
# TLS, such as what an appender does with the connection it inherited from the parent process after a fork.
#
# It numbers the connections it accepts from 1, and records what it reads on each: each record, up to the
# separator, without it, or with http: true the body of each HTTP request, which it answers with 204 No Content.
# Once a connection ends, such as when the client sends a TLS close_notify, or what it reads cannot be
# decrypted, it records :closed for that connection.
class TlsServer
  attr_reader :port

  # Returns [OpenSSL::SSL::SSLContext] the server's context, with a self-signed certificate for 127.0.0.1. An
  # RSA key, since the gelf gem's TLS client leaves out ECDSA ciphers.
  def self.context
    @context ||= begin
      key                    = OpenSSL::PKey::RSA.new(2048)
      certificate            = OpenSSL::X509::Certificate.new
      certificate.version    = 2
      certificate.serial     = 1
      certificate.subject    = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
      certificate.issuer     = certificate.subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 60
      certificate.not_after  = Time.now + 3600
      certificate.sign(key, OpenSSL::Digest.new("SHA256"))

      context      = OpenSSL::SSL::SSLContext.new
      context.cert = certificate
      context.key  = key
      context
    end
  end

  def initialize(separator: "\n", http: false)
    @context   = self.class.context
    @separator = separator
    @http      = http
    @server    = TCPServer.new("127.0.0.1", 0)
    @port      = @server.addr[1]
    @events    = Thread::Queue.new
    @received  = Hash.new { |received, connection| received[connection] = [] }
    @sockets   = Thread::Queue.new
    @thread    = Thread.new { accept_connections }
  end

  # Returns [Array] what the given connection received, once it has received the given number of records,
  # counting :closed, or 5 seconds after it is called.
  def received(connection, count)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while @received[connection].size < count
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      event     = remaining.positive? && @events.pop(timeout: remaining)
      break unless event

      @received[event.first] << event.last
    end
    @received[connection]
  end

  def close
    @thread.kill.join
    @server.close
    @sockets.close
    while (socket = @sockets.pop)
      socket.close
    end
  end

  private

  def accept_connections
    connection = 0
    loop do
      socket = @server.accept
      @sockets << socket
      connection += 1
      Thread.new(connection, socket) { |number, accepted| serve(number, accepted) }
    end
  end

  def serve(connection, socket)
    ssl            = OpenSSL::SSL::SSLSocket.new(socket, @context)
    ssl.sync_close = true
    ssl.accept
    while (record = @http ? read_request(ssl) : ssl.gets(@separator))
      @events << [connection, @http ? record : record.chomp(@separator)]
    end
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  ensure
    @events << [connection, :closed]
  end

  # Returns [String] the body of the next HTTP request, which it answers with 204 No Content, or nil once the
  # client has ended the connection.
  def read_request(ssl)
    return unless ssl.gets

    length = 0
    while (line = ssl.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      length      = value.to_i if name.casecmp?("Content-Length")
    end
    return unless line

    body = ssl.read(length)
    ssl.write("HTTP/1.1 204 No Content\r\n\r\n")
    body
  end
end
