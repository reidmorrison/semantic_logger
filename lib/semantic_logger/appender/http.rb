require 'net/http'
require 'uri'
require 'socket'
begin
  require 'json'
rescue LoadError
  raise 'Gem json is required for logging with JSON to HTTP. Please add the gem "json" to your Gemfile.'
end

# Log to any HTTP(S) server that accepts log messages in JSON form
#
# Features:
# * JSON Formatted messages.
# * For better performance uses a persistent http connection if the server supports it.
# * SSL encryption (https).
#
# Example:
#   appender = SemanticLogger::Appender::Http.new(
#     url:   'http://localhost:8088/path'
#   )
#   # Optional: Exclude health_check log entries
#   appender.filter = Proc.new { |log| log.message !~ /(health_check|Not logged in)/}
#
#   SemanticLogger.add_appender(appender)

class SemanticLogger::Appender::Http < SemanticLogger::Appender::Base
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
  #   hostname: [String]
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
    @hostname         = options.delete(:hostname) || Socket.gethostname
    raise(ArgumentError, "Unknown options: #{options.inspect}") if options.size > 0

    raise(ArgumentError, 'Missing mandatory parameter :url') unless @url

    @header = {'Content-Type' => 'application/json'}

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
    request.body = formatter.call(log)
    request.basic_auth(@username, @password) if @username
    # TODO Connection retries
    response = @http.request(request)
    if response.code != '200'
      SemanticLogger::Logger.logger.error("Bad response code #{response.code} from Splunk: #{response.body}")
    end
    true
  end

  def default_formatter
    proc do |log|
      # Header
      h          = {
        pid:         $$,
        thread:      log.thread_name,
        timestamp:   log.time.utc.to_f,
        level:       log.level.to_s,
        application: @application_name
      }
      file, line = log.file_name_and_line
      if file
        h[:file] = file
        h[:line] = line
      end

      # Tags
      h[:tags]     = log.tags if log.tags && (log.tags.size > 0)

      # Duration
      h[:duration] = log.duration_human if log.duration

      # Class / app name
      h[:name]     = log.name

      # Log message
      h[:message]  = log.cleansed_message if log.message

      # Payload
      if log.payload
        if log.payload.is_a?(Hash)
          h.merge!(log.payload)
        else
          h[:payload] = log.payload
        end
      end

      # Exceptions
      if log.exception
        if log.message
          h[:message] << ' -- '
        else
          h[:message] = ''
        end
        h[:message] << "#{log.exception.class.name}: #{log.exception.message}"
        h[:backtrace] = log.backtrace_to_s
      end

      # Metric
      h[:metric] = log.metric if log.metric
      h.to_json
    end
  end

end
