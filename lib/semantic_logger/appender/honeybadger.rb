begin
  require 'honeybadger'
rescue LoadError
  raise 'Gem honeybadger is required for logging purposes. Please add the gem "honeybadger" to your Gemfile.'
end

# Send log messages to honeybadger
#
# Example:
#   SemanticLogger.add_appender(appender: :honeybadger)
#
class SemanticLogger::Appender::Honeybadger < SemanticLogger::Appender::Base
  # Create Appender
  #
  # Parameters
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender.
  #     Default: :error
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
    options  = {level: options} unless options.is_a?(Hash)
    @options = options.dup
    level    = @options.delete(:level) || :error

    super(level, &block)
  end

  # Send an error notification to honeybadger
  def log(log)
    return false if (level_index > (log.level_index || 0)) ||
      !include_message?(log) # Filtered out?

    if log.exception
      Honeybadger.notify(log.exception, log.to_h)
    else
      message = {
        error_class:   log.name,
        error_message: log.message,
        backtrace:     log.backtrace,
        context:       log.to_h,
      }
      Honeybadger.notify(message)
    end
    true
  end

end
