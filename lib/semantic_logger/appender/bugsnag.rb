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
    # Replace the Bugsnag logger so that we can identify its log messages and not forward them to Bugsnag
    Bugsnag.configure { |config| config.logger = SemanticLogger[Bugsnag] }
    super(level, &block)
  end

  # Returns [Hash] of parameters to send to Bugsnag.
  def default_formatter
    proc do |log|
      h = {severity: log_level(log), tags: log.tags, class: log.name}
      h[:message] = log.message if log.exception
      h.merge!(log.payload) if log.payload
      h
    end
  end

  # Send an error notification to Bugsnag
  def log(log)
    # Only log if level is warn, or error.
    return false if (level_index > (log.level_index || 0)) ||
      # We don't want to send fatal as those are already captured by Bugsnag.
      (log.level == :fatal) ||
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
    Bugsnag.notify(exception, formatter.call(log))
    true
  end

  private

  def log_level(log)
    log.level == :warn ? 'warning' : log.level.to_s
  end
end
