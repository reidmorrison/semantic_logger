begin
  require "newrelic_rpm"
rescue LoadError
  raise LoadError,
        'Gem newrelic_rpm is required for logging to New Relic. Please add the gem "newrelic_rpm" to your Gemfile.'
end

# Send Metrics to NewRelic
#
# Records the metric of each log entry that has one as a New Relic custom metric, through the
# agent's metric API: with record_metric, in seconds, when the entry has a duration, otherwise with
# increment_metric, by its metric_amount, or 1. A metric's dimensions are left out, since that API
# takes none.
#
# Example:
#   SemanticLogger.add_appender(metric: :new_relic)
module SemanticLogger
  module Metric
    class NewRelic < SemanticLogger::Subscriber
      attr_accessor :prefix

      # Create the New Relic metrics subscriber
      #
      # Parameters
      #   prefix: [String]
      #     Prefix to add to every metric name that does not already start with it, before
      #     forwarding to NewRelic. Only the default formatter, #call, adds it.
      #     Default: 'Custom'
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this subscriber.
      #     Default: SemanticLogger.default_level
      #
      #   formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc, that returns the name to
      #     record the metric under.
      #     Default: #call, which adds the prefix to the name of the entry's metric.
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      def initialize(prefix: "Custom", **args, &)
        @prefix = prefix
        super(**args, &)
      end

      # Returns metric name to use.
      def call(log, _logger)
        metric = log.metric
        # Add prefix for NewRelic
        metric = "#{prefix}/#{metric}" unless metric.start_with?(prefix)
        metric
      end

      def log(log)
        name = format_log(log)
        if (duration = log.duration)
          # Convert duration to seconds
          ::NewRelic::Agent.record_metric(name, duration / 1000.0)
        else
          ::NewRelic::Agent.increment_metric(name, log.metric_amount || 1)
        end
        true
      end

      # Only forward log entries that contain metrics.
      def should_log?(log)
        # Records a metric that has dimensions under its name alone, since the agent's metric API has none.
        log.metric && meets_log_level?(log) && !filtered?(log)
      end
    end
  end
end
