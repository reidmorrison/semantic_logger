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
class SemanticLogger::Appender::Honeybadger < SemanticLogger::Subscriber
  # Honeybadger Appender
  #
  # Parameters
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender.
  #     Default: :error
  #
  #   formatter: [Object|Proc|Symbol|Hash]
  #     An instance of a class that implements #call, or a Proc to be used to format
  #     the output from this appender
  #     Default: Use the built-in formatter (See: #call)
  #
  #   filter: [Regexp|Proc]
  #     RegExp: Only include log messages where the class name matches the supplied.
  #     regular expression. All other messages will be ignored.
  #     Proc: Only include log messages where the supplied Proc returns true
  #           The Proc must return true or false.
  #
  #   host: [String]
  #     Name of this host to appear in log messages.
  #     Default: SemanticLogger.host
  #
  #   application: [String]
  #     Name of this application to appear in log messages.
  #     Default: SemanticLogger.application
  def initialize(level: :error, formatter: nil, filter: nil, application: nil, host: nil, &block)
    super(level: level, formatter: formatter, filter: filter, application: application, host: host, &block)
  end

  # Send an error notification to honeybadger
  def log(log)
    return false unless should_log?(log)

    formatted = formatter.call(log, self)
    begin
      Honeybadger.context(formatted[:context])
      Honeybadger.with_rack_env(formatted[:rack_env]) do
        Honeybadger.notify(formatted[:message], formatted[:options])
      end
    ensure
      Honeybadger.context.clear!
    end

    return true
  end

  private

  # Use Honeybadger formatter by default
  def default_formatter
    return SemanticLogger::Formatters::Honeybadger.new
  end

  # Capture thread-local context at log-time
  module CaptureContext
    def self.call(log)
      manager = Honeybadger::ContextManager.current
      log.set_context(:honeybadger, context: manager.get_context.dup, rack_env: manager.get_rack_env.dup)
    end
  end
  SemanticLogger.on_log(CaptureContext)
end
