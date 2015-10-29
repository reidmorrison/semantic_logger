=begin
New Relic appender for SemanticLogger

The :error and :fatal log entries will show up under Applications > "Application Name" > Events > Errors in New Relic

Note: Payload information is not filtered, so take care not to push any sensitive information when logging with tags or a payload.


Example 1

Adding the New Relic appender will send :error and :fatal log entries to New Relic as error events.

For a Rails application already configured to use SemanticLogger and New Relic, create a file called <Rails Root>/config/initializers/newrelic_appender.rb with the following contents and restart the application:

# Send :error and :fatal log messages to New Relic
SemanticLogger.add_appender(SemanticLogger::Appender::NewRelic.new)
Rails.logger.info 'SemanticLogger New Relic Appender added.'


Example 2

For a non-Rails application, send :info and more severe log entries to a file called application.log and also send :error and :fatal log entries to New Relic.

# ./newrelic.yml needs to be set up -- see https://docs.newrelic.com/docs/ruby/ruby-agent-installation for more information.

require 'semantic_logger'
require 'newrelic_rpm'

# New Relic setup
NewRelic::Agent.manual_start

# SemanticLogger setup
SemanticLogger.default_level = :info
SemanticLogger.add_appender('application.log')
SemanticLogger.add_appender(SemanticLogger::Appender::NewRelic.new)
logger = SemanticLogger['Example']

# Log some messages
logger.info  'This is only written to application.log'
logger.error 'This is written to application.log and will also be sent to New Relic as an error event'

# The appender will send tags, payloads and benchmark duration to New Relic
logger.tagged('test') do
  logger.with_payload( {key1: 123, key2: 'abc'} ) do
    logger.benchmark_error(@message) do
      sleep 0.001
    end
  end
end

# New Relic does not seem to receive any errors if the application exits too soon after sending error alerts.
sleep 10

# New Relic shutdown - should send any queued data before exiting
::NewRelic::Agent.shutdown
=end


require 'newrelic_rpm'

class SemanticLogger::Appender::NewRelic < SemanticLogger::Appender::Base
  # Allow the level for this appender to be overwritten
  #   Default: :error
  #   Note: Not recommended to set the log level to :info, :debug, or :trace as that would flood NewRelic with Error notices
  def initialize(level=:error, &block)
    super(level, &block)
  end

  # Returns [Hash] of parameters to send to New Relic.
  def default_formatter
    Proc.new do |log|
      custom_params            = {thread_name: log.thread_name}
      custom_params[:duration] = "#{log.duration} ms" if log.duration
      custom_params[:payload]  = log.payload if log.payload
      custom_params[:tags]     = log.tags if log.tags && (log.tags.size > 0)

      {metric: log.metric, custom_params: custom_params}
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
    NewRelic::Agent.notice_error(exception, formatter.call(log))
    true
  end

end
