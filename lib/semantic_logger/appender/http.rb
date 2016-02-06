require 'net/http'
require 'uri'
require 'socket'
require 'json'

# Log to any HTTP(S) server that accepts log messages in JSON form
#
# Features:
# * JSON Formatted messages.
# * Uses a persistent http connection, if the server supports it.
# * SSL encryption (https).
#
# Example:
#   appender = SemanticLogger::Appender::Http.new(
#     url: 'http://localhost:8088/path'
#   )
#
#   # Optional: Exclude health_check log entries, etc.
#   appender.filter = Proc.new { |log| log.message !~ /(health_check|Not logged in)/}
#
#   SemanticLogger.add_appender(appender)
class SemanticLogger::Appender::Http < SemanticLogger::Appender::Base
  attr_accessor :application_name, :host_name, :compress
  attr_reader :http

  # Create HTTP(S) log appender
  #
  # Parameters:
  #   url: [String]
  #     Valid URL to post to.
  #       Example: http://example.com/some_path
  #     To enable SSL include https in the URL.
  #       Example: https://example.com/some_path
  #       verify_mode will default: OpenSSL::SSL::VERIFY_PEER
  #
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender
  #     Default: SemanticLogger.default_level
  #
  #   application_name: [String]
  #     Name of this application to appear in log messages.
  #
  #   host_name: [String]
  #     Name of this host to appear in log messages.
  #     Default: Socket.gethostname
  #
  #   username: [String]
  #     User name for basic Authentication.
  #     Default: nil ( do not use basic auth )
  #
  #   password: [String]
  #     Password for basic Authentication.
  #
  #   compress: [true|false]
  #     Whether to compress the JSON string with GZip
  #     Default: false
  #
  #   ssl: [Hash]
  #     Specific SSL options: For more details see NET::HTTP.start
  #       ca_file, ca_path, cert, cert_store, ciphers, key, open_timeout, read_timeout, ssl_timeout,
  #       ssl_version, use_ssl, verify_callback, verify_depth and verify_mode.
  def initialize(options, &block)
    options           = options.dup
    level             = options.delete(:level)
    @url              = options.delete(:url)
    @ssl_options      = options.delete(:ssl)
    @username         = options.delete(:username)
    @password         = options.delete(:password)
    @application_name = options.delete(:application_name) || 'Semantic Logger'
    @host_name        = options.delete(:host_name) || Socket.gethostname
    @compress         = options.delete(:compress) || false
    raise(ArgumentError, "Unknown options: #{options.inspect}") if options.size > 0

    raise(ArgumentError, 'Missing mandatory parameter :url') unless @url

    @header                     = {
      'Accept'       => 'application/json',
      'Content-Type' => 'application/json',
    }
    @header['Content-Encoding'] = 'gzip' if @compress

    reopen

    # Pass on the level and custom formatter if supplied
    super(level, &block)
  end

  # Re-open after process fork
  def reopen
    uri                             = URI.parse(@url)
    (@ssl_options ||= {})[:use_ssl] = true if uri.scheme == 'https'

    @http = @ssl_options ? Net::HTTP.new(uri.host, uri.port, @ssl_options) : Net::HTTP.new(uri.host, uri.port)

    @request_uri = uri.request_uri
  end

  # Used for testing the JSON format
  def test(json)
    request      = Net::HTTP::Post.new(@request_uri, @header)
    request.body = json
    request.basic_auth(@username, @password) if @username
    response = @http.request(request)
  end

  # Forward log messages to HTTP Server
  def log(log)
    return false if (level_index > (log.level_index || 0)) ||
      !include_message?(log) # Filtered out?

    # Exceptions will be logged to the global semantic logger failsafe logger (Usually stderr or file)
    request      = Net::HTTP::Post.new(@request_uri, @header)
    body         = formatter.call(log, self, request)
    body         = compress_data(body) if compress
    request.body = body
    request.basic_auth(@username, @password) if @username
    response = @http.request(request)
    if response.code == '200'
      true
    else
      SemanticLogger::Logger.logger.error("Bad response code #{response.code} from Splunk: #{response.body}")
      false
    end
  end

  def default_formatter
    Proc.new do |log, logger, request|
      h = log.to_h
      h.delete(:time)
      h[:application] = logger.application_name
      h[:host]        = logger.host_name
      h[:timestamp]   = log.time.utc.iso8601(defined?(JRuby) ? 3 : 6)

      # Render to JSON
      h.to_json
    end
  end

  private

  def compress_data(data)
    str = StringIO.new
    gz  = Zlib::GzipWriter.new(str)
    gz << data
    gz.close
    str.string
  end

end
