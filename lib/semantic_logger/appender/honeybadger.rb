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
  # Create Appender
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
  def initialize(options = {}, &block)
    options = options.is_a?(Hash) ? options.dup : { level: options }
    options[:level] ||= :error
    super(options, &block)
  end

  # Send an error notification to honeybadger
  # Takes into account the request/context set on the caller thread
  def log(log)
    return false unless should_log?(log)

    options = formatter.call(log, self)

    context = options.delete(:context)
    Honeybadger.context(context) if context
    Honeybadger::Agent.config.with_request(options.delete(:request)) do
      Honeybadger.notify(options)
    end

    return true
  ensure
    Honeybadger.context.clear!
  end

  def before_log(log)
    if should_log?(log)
      context = {}
      context[:request] = Honeybadger::Agent.config.request.dup unless Honeybadger::Agent.config.request.nil?
      context[:context] = Honeybadger.get_context.dup unless Honeybadger.get_context.nil?

      log.appender_context[self.class] = context unless context.empty?
    end
  end

  def default_formatter
    return SemanticLogger::Formatters::Honeybadger.new
  end
end
