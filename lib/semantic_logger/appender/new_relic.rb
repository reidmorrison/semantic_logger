begin
  require 'newrelic_rpm'
rescue LoadError
  raise 'Gem newrelic_rpm is required for logging to New Relic. Please add the gem "newrelic_rpm" to your Gemfile.'
end

# Send log messages to NewRelic
#
# The :error and :fatal log entries will show up under
# "Applications" > "Application Name" > "Events" > "Errors" in New Relic.
#
# Example:
#   SemanticLogger.add_appender(SemanticLogger::Appender::NewRelic.new)
#
class SemanticLogger::Appender::NewRelic < SemanticLogger::Appender::Base
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
    # Backward compatibility
    options  = {level: options} unless options.is_a?(Hash)
    @options = options.dup
    level    = @options.delete(:level) || :error
    filter   = @options.delete(:filter)

    super(level, filter, &block)
  end

  # Returns [Hash] of parameters to send to New Relic.
  def default_formatter
    Proc.new do |log, logger|
      h = log.to_h
      h.delete(:time)
      h.delete(:exception)
      {metric: log.metric, custom_params: h}
    end
  end

  # Send an error notification to New Relic
  def log(log)
    # Ensure minimum log level is met, and check filter
    return false if (level_index > (log.level_index || 0)) || !include_message?(log)

    # Send error messages as Runtime exceptions
    exception =
      if log.exception
        log.exception
      else
        error = RuntimeError.new(log.message)
        error.set_backtrace(log.backtrace) if log.backtrace
        error
      end
    # For more documentation on the NewRelic::Agent.notice_error method see:
    # http://rubydoc.info/github/newrelic/rpm/NewRelic/Agent#notice_error-instance_method
    # and https://docs.newrelic.com/docs/ruby/ruby-agent-api
    NewRelic::Agent.notice_error(exception, formatter.call(log, self))
    true
  end

end
