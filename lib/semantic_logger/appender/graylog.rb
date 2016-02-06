begin
  require 'gelf'
rescue LoadError
  raise 'Gem gelf is required for logging to Graylog. Please add the gem "gelf" to your Gemfile.'
end

# Forward log entries to a Graylog server.
#
# Example:
#   appender        = SemanticLogger::Appender::Graylog.new(
#     server:   'localhost',
#     port:     12201,
#     protocol: :tcp,
#     facility: Rails.application.class.name
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
# In the Graylog search, it is recommended to turn on / include the following fields:
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
  #   level: [Symbol]
  #     Any valid SemanticLogger log level, for example :trace, :debug, :info, :warn, :error, :fatal
  #     Default: SemanticLogger.default_level
  #   server: [String]
  #     Default: "localhost"
  #   port: [Integer]
  #     Default: 12201
  #   max_size: [String]
  #     Ignored when protocol is :tcp
  #     Default: "WAN"
  #   hostname: [String]
  #     Name of this host to appear in graylog
  #     Default: Socket.gethostname
  #   facility: [String]
  #     Default: 'Semantic Logger'
  #   protocol: Symbol
  #     :tcp or :udp
  #     Default: :udp
  def initialize(options={}, &block)
    @options  = options.dup
    level     = @options.delete(:level)
    @server   = @options.delete(:server) || 'localhost'
    @port     = (@options.delete(:port) || 12201).to_i
    @max_size = @options.delete(:max_size) || 'WAN'
    if protocol = @options.delete(:protocol)
      raise(ArgumentError, "Invalid protocol value: #{protocol}. Must be :udp or :tcp") unless [:udp, :tcp].include?(protocol)
      @options[:protocol] = protocol == :tcp ? GELF::Protocol::TCP : GELF::Protocol::UDP
    end
    if source = @options.delete(:hostname)
      @options[:host] = source
    end
    @options[:facility] ||= 'Semantic Logger'
    reopen
    super(level, &block)
  end

  # Re-open after process fork
  def reopen
    @notifier                       = GELF::Notifier.new(@server, @port, @max_size, @options)
    @notifier.collect_file_and_line = false
  end

  # Returns [Hash] of parameters to send
  def default_formatter
    Proc.new do |log|
      h = log.to_h
      h.delete(:time)
      h[:timestamp]     = log.time.utc.to_f
      h[:level]         = SemanticLogger::Appender::Graylog::LEVEL_MAP[log.level]
      h[:level_str]     = log.level.to_s
      h[:short_message] = h.delete(:message) if log.message
      h
    end
  end

  # Forward log messages
  def log(log)
    return false if (level_index > (log.level_index || 0)) ||
      !include_message?(log) # Filtered out?

    @notifier.notify!(formatter.call(log, self))
    true
  end

end
