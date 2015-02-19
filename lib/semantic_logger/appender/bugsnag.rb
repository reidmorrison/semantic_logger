=begin
Bugsnag appender for SemanticLogger

Skips the fatal log level because unrescued exceptions get logged as fatal and will be reported automatically by Bugsnag.

Note: Payload information is not filtered, so take care not to push any sensitive information when logging with tags or a payload.

Example 1

Adding the Bugsnag appender will send :error log entries to Bugsnag with the error severity.

For a Rails application already configured to use SemanticLogger and Bugsnag, create a file called <Rails Root>/config/initializers/bugsnag_appender.rb with the following contents and restart the application:

# Send :error and log messages to Bugsnag
SemanticLogger.add_appender(SemanticLogger::Appender::Bugsnag.new)
Rails.logger.info 'SemanticLogger Bugsnag Appender added.'

Example 2

For a non-Rails application, send :info and more severe log entries to a file called application.log and also send :error log entries to Bugsnag.

# ./newrelic.yml needs to be set up -- see https://docs.newrelic.com/docs/ruby/ruby-agent-installation for more information.

require 'semantic_logger'
require 'bugsnag'

# Bugsnag setup
Bugsnag.configure do |config|
  config.api_key = 'abc123'
end

# SemanticLogger setup
SemanticLogger.default_level = :info
SemanticLogger.add_appender('application.log')
SemanticLogger.add_appender(SemanticLogger::Appender::Bugsnag.new)
logger = SemanticLogger['Example']

# Log some messages
logger.info  'This is only written to application.log'
logger.error 'This is written to application.log and will also be sent to Bugsnag as an error event'

# The appender will send payloads to Bugsnag
logger.error 'Something bad happened', info: 'Related information'
=end

require 'bugsnag'

class SemanticLogger::Appender::Bugsnag < SemanticLogger::Appender::Base
  # Allow the level for this appender to be overwritten
  #   Default: :error
  #   Note: Not recommended to set the log level to :info, :debug, or :trace as that would flood Bugsnag with Error notices
  def initialize(level = :error, &block)
    super(level, &block)
  end

  # Returns [Hash] of parameters to send to Bugsnag.
  def default_formatter
    proc do |log|
      { :severity => log_level(log), tags: log.tags }.merge(Hash(log.payload))
    end
  end

  # Send an error notification to Bugsnag
  def log(log)
    # Only log if level is warn, or error.
    # We don't want to send fatal as those are already captured by Bugsnag.
    return false if (level_index > (log.level_index || 0)) || !include_message?(log)
    return false if log.level == :fatal
    # Ignore logs coming from Bugsnag itself
    return false if log.message.to_s.include?(Bugsnag::LOG_PREFIX)

    # For more documentation on the Bugsnag.notify method see:
    # https://bugsnag.com/docs/notifiers/ruby#sending-handled-exceptions
    Bugsnag.notify(log.exception || log.message, formatter.call(log))
    true
  end

  private

  def log_level(log)
    log.level.to_s.gsub('warn', 'warning')
  end
end
