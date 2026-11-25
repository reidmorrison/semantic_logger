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
      # The capture of New Relic's linking metadata, which its formatter writes (see
      # Formatters::NewRelicLogs#source_captures).
      CAPTURE_CONTEXT = SemanticLogger::Formatters::NewRelicLogs::CAPTURE_CONTEXT

      # Create Appender
      #
      # Parameters
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: none (:trace), so it writes every entry that a logger emits; each logger
      #     filters by its own level.
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
      #
      # Its formatter, NewRelicLogs by default, has New Relic's linking metadata, such as "trace.id",
      # captured on the thread that logs each entry (see Formatters::NewRelicLogs#source_captures).
      def initialize(formatter: nil, **args, &block)
        super
      end

      # Send the log entry to the New Relic agent, which forwards it to New Relic Logs.
      #
      # Raises any error, as other appenders do, so that the asynchronous appender or the appenders
      # that called it can count and report it (see #message_error?).
      def log(log)
        message      = format_log(log) # Generate the structured log
        json_message = Utils.to_json(message) # Convert the log to JSON, repairing any non UTF-8 data
        level        = log.level.to_s.upcase # Determine the log level
        self.class.log_newrelic(json_message, level)
        true
      end

      # Every error that #log raises is one that writing the entry again cannot fix, so an
      # asynchronous appender discards the entry, counts it and reports it, rather than backing off.
      #
      # The agent's LogEventAggregator#record only adds the entry to the agent's own buffer in this
      # process, and rescues any StandardError of its own; the agent sends that buffer to New Relic
      # later, on its own thread. So nothing here waits on New Relic, and an error comes either from
      # the entry, when it cannot be formatted or converted to JSON, or from the agent not being
      # available, before newrelic_rpm has been initialized, when NewRelic::Agent.agent is nil, such as
      # during Rails boot before its initializer runs. An agent that is initialized but not started, or
      # disabled, is not nil, and drops the entry itself without raising. Backing off for
      # the latter would hold up every entry, and stop the worker thread after async_max_retries,
      # dropping every entry after it, even once the agent has started.
      def message_error?(_exception)
        true
      end

      def self.log_newrelic(json_message, level)
        ::NewRelic::Agent.agent.log_event_aggregator.record(json_message, level)
      end

      private

      # Use the New Relic Logs formatter by default
      def default_formatter
        SemanticLogger::Formatters::NewRelicLogs.new
      end
    end
  end
end
