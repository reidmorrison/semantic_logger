begin
  require "newrelic_rpm"
rescue LoadError
  raise LoadError,
        'Gem newrelic_rpm is required for logging to New Relic. Please add the gem "newrelic_rpm" to your Gemfile.'
end

require "semantic_logger/formatters/new_relic_logs"

# Send log messages to NewRelic
#
# All log entries will appear under
# "Logs" in New Relic
#
# == Caveats
#
# * The NewRelic agent only sends logs to NewRelic when log forwarding is enabled. There is however an open
#   issue to get this fixed: https://github.com/newrelic/newrelic-ruby-agent/issues/1614. Please see the guide
#   for a workaround.
#
# Example:
#   SemanticLogger.add_appender(appender: :new_relic_logs)
module SemanticLogger
  module Appender
    class NewRelicLogs < SemanticLogger::Subscriber
      # Create Appender
      #
      # Parameters
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: SemanticLogger::Formatters::NewRelicLogs
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      def initialize(formatter: SemanticLogger::Formatters::NewRelicLogs.new, **args, &block)
        super
      end

      # Send an error notification to New Relic
      def log(log)
        begin
          message = formatter.call(log, self) # Generate the structured log
          json_message = message.to_json      # Convert the log to JSON
          level = log.level.to_s.upcase       # Determine the log level
          self.class.log_newrelic(json_message, level)
        rescue JSON::GeneratorError => e
          warn("Failed to serialize log message to JSON: #{e.message}")
          warn("Problematic data: #{message.inspect}")
        rescue StandardError => e
          warn("Unexpected error while logging to New Relic: #{e.message}")
        end
        true
      end

      def self.log_newrelic(json_message, level)
        ::NewRelic::Agent.agent.log_event_aggregator.record(json_message, level)
      end
    end
  end
end
