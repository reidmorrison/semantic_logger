begin
  require 'bugsnag'
rescue LoadError
  raise 'Gem bugsnag is required for logging purposes. Please add the gem "bugsnag" to your Gemfile.'
end

# Send log messages to Bugsnag
#
# Example:
#   SemanticLogger.add_appender(SemanticLogger::Appender::Bugsnag.new)
#
class SemanticLogger::Appender::Bugsnag < SemanticLogger::Appender::Base
  # Create Appender
  #
  # Parameters
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender.
  #     Default: :error
  #
  #   filter: [Regexp|Proc]
  #     RegExp: Only include log messages where the class name matches the supplied.
  #     regular expression. All other messages will be ignored.
  #     Proc: Only include log messages where the supplied Proc returns true
  #           The Proc must return true or false.
  def initialize(options = {}, &block)
    options  = {level: options} unless options.is_a?(Hash)
    @options  = options.dup
    level     = @options.delete(:level) || :error
    filter    = @options.delete(:filter)

    raise 'Bugsnag only supports :info, :warn, or :error log levels' unless [:info, :warn, :error].include?(level)

    # Replace the Bugsnag logger so that we can identify its log messages and not forward them to Bugsnag
    Bugsnag.configure { |config| config.logger = SemanticLogger[Bugsnag] }
    super(level, &block)
  end

  # Returns [Hash] of parameters to send to Bugsnag.
  def default_formatter
    Proc.new do |log|
      h            = log.to_h
      h[:severity] = log_level(log)
      h.delete(:time)
      h.delete(:exception)
      h
    end
  end

  # Send an error notification to Bugsnag
  def log(log)
    # Only log if level is warn, or error.
    return false if (level_index > (log.level_index || 0)) ||
      # Ignore logs coming from Bugsnag itself
      (log.name == 'Bugsnag') ||
      # Filtered out?
      !include_message?(log)

    # Send error messages as Runtime exceptions
    exception =
      if log.exception
        log.exception
      else
        error = RuntimeError.new(log.message)
        error.set_backtrace(log.backtrace) if log.backtrace
        error
      end

    # For more documentation on the Bugsnag.notify method see:
    # https://bugsnag.com/docs/notifiers/ruby#sending-handled-exceptions
    Bugsnag.notify(exception, formatter.call(log, self))
    true
  end

  private

  # Bugsnag supports: error, warning or info
  def log_level(log)
    case log.level
    when :error, :fatal
      'error'
    when :warn
      'warning'
    else
      'info'
    end
  end
end
