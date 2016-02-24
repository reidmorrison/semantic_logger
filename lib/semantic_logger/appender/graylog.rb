require 'uri'
begin
  require 'gelf'
rescue LoadError
  raise 'Gem gelf is required for logging to Graylog. Please add the gem "gelf" to your Gemfile.'
end

# Forward log entries to a Graylog server.
#
# Example:
#   appender        = SemanticLogger::Appender::Graylog.new(
#     url: 'udp://localhost:12201'
#   )
#
#   # Optional: Add filter to exclude health_check, or other log entries
#   appender.filter = Proc.new { |log| log.message !~ /(health_check|Not logged in)/ }
#
#   SemanticLogger.add_appender(appender)
#
# Notes:
# * trace is not supported by Graylog, so trace level logging will appear as debug in Graylog.
#
# In the Graylog Web UI search screen, it is recommended to include the following fields:
#  `duration`, `level`, `message`, `metric`, `name`, `tags
class SemanticLogger::Appender::Graylog < SemanticLogger::Appender::Base
  # Map Semantic Logger levels to Graylog levels
  LEVEL_MAP = {
    fatal: GELF::FATAL,
    error: GELF::ERROR,
    warn:  GELF::WARN,
    info:  GELF::INFO,
    debug: GELF::DEBUG,
    trace: GELF::DEBUG
  }

  attr_reader :notifier

  # Create Graylog log appender.
  #
  # Options:
  #   url: [String]
  #     Valid URL to post to.
  #     Log to UDP Example:
  #       'udp://localhost:12201'
  #     Log to TCP Example:
  #       'tcp://localhost:12201'
  #     Default: 'udp://localhost:12201'
  #
  #   host: [String]
  #     Name of this host to appear in log messages.
  #     Default: Socket.gethostname
  #
  #   application: [String]
  #     Name of this application to appear in log messages.
  #     Default: SemanticLogger.application
  #
  #   max_size: [String]
  #     Max udp packet size. Ignored when protocol is :tcp
  #     Default: "WAN"
  #
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender.
  #     Default: SemanticLogger.default_level
  #
  #   formatter: [Object|Proc]
  #     An instance of a class that implements #call, or a Proc to be used to format
  #     the output from this appender
  #     Default: Use the built-in formatter (See: #call)
  #
  #   filter: [Regexp|Proc]
  #     RegExp: Only include log messages where the class name matches the supplied.
  #     regular expression. All other messages will be ignored.
  #     Proc: Only include log messages where the supplied Proc returns true
  #           The Proc must return true or false.
  def initialize(options = {}, &block)
    @gelf_options = options.dup
    @url          = @gelf_options.delete(:url) || 'udp://localhost:12201'
    @max_size     = @gelf_options.delete(:max_size) || 'WAN'

    uri      = URI.parse(@url)
    @server  = uri.host
    @port    = uri.port
    protocol = uri.scheme.to_sym

    raise(ArgumentError, "Invalid protocol value: #{protocol}. Must be :udp or :tcp") unless [:udp, :tcp].include?(protocol)

    @gelf_options[:protocol] = protocol == :tcp ? GELF::Protocol::TCP : GELF::Protocol::UDP
    @gelf_options[:facility] = @gelf_options.delete(:application) || SemanticLogger.application

    options = {
      level:     @gelf_options.delete(:level),
      filter:    @gelf_options.delete(:filter),
      formatter: @gelf_options.delete(:formatter)
    }
    reopen

    super(options, &block)
  end

  # Re-open after process fork
  def reopen
    @notifier                       = GELF::Notifier.new(@server, @port, @max_size, @gelf_options)
    @notifier.collect_file_and_line = false
  end

  # Returns [Hash] of parameters to send
  def call(log, logger)
    h = log.to_h
    h.delete(:time)
    h[:timestamp]     = log.time.utc.to_f
    h[:level]         = logger.map_level(log)
    h[:level_str]     = log.level.to_s
    h[:short_message] = h.delete(:message) if log.message
    h
  end

  # Forward log messages
  def log(log)
    return false if (level_index > (log.level_index || 0)) ||
      !include_message?(log) # Filtered out?

    @notifier.notify!(formatter.call(log, self))
    true
  end

  # Returns the Graylog level for the supplied log message
  def map_level(log)
    LEVEL_MAP[log.level]
  end

end
