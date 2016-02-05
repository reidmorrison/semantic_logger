begin
  require 'gelf'
rescue LoadError
  raise 'Gem gelf is required for logging to Graylog. Please add the gem "gelf" to your Gemfile.'
end

# Forward log entries to a Graylog server.
#
# Example:
#   SemanticLogger.add_appender(SemanticLogger::Appender::Graylog.new)
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
  #     Default: "gelf-rb"
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
    proc do |log|
      h          = {}
      # Header
      h[:pid]    = $$
      h[:thread] = log.thread_name
      file, line = log.file_name_and_line
      if file
        h[:file] = file
        h[:line] = line
      end
      h[:timestamp]     = log.time.utc.to_f
      h[:level]         = SemanticLogger::Appender::Graylog::LEVEL_MAP[log.level]

      # Tags
      h[:tags]          = log.tags if log.tags && (log.tags.size > 0)

      # Duration
      h[:duration]      = log.duration_human if log.duration

      # Class / app name
      h[:name]          = log.name

      # Log message
      h[:short_message] = log.cleansed_message if log.message

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
          h[:short_message] << " -- "
        else
          h[:short_message] = ''
        end
        h[:short_message] << "#{log.exception.class.name}: #{log.exception.message}"
        h[:backtrace] = log.backtrace_to_s
      end

      # Metric
      h[:metric] = log.metric if log.metric
      h
    end
  end

  # Forward log messages
  def log(log)
    return false if (level_index > (log.level_index || 0)) ||
      !include_message?(log) # Filtered out?

    @notifier.notify!(formatter.call(log))
    true
  end

end
