begin
  require "newrelic_rpm"
rescue LoadError
  raise LoadError, 'Gem newrelic_rpm is required for logging to New Relic. Please add the gem "newrelic_rpm" to your Gemfile.'
end

# Send Metrics to NewRelic
#
# The :error and :fatal log entries will show up under
# "Applications" > "Application Name" > "Events" > "Errors" in New Relic.
#
# Example:
#   SemanticLogger.add_appender(metric: :new_relic)
module SemanticLogger
  module Metric
    class NewRelic < SemanticLogger::Subscriber
      attr_accessor :prefix

      # Create Appender
      #
      # Parameters
      #   :prefix [String]
      #     Prefix to add to every metric before forwarding to NewRelic.
      #     Default: 'Custom'
      #
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
      def initialize(prefix: "Custom", **args, &block)
        @prefix = prefix
        super(**args, &block)
      end

      # Returns metric name to use.
      def call(log, _logger)
        metric = log.metric
        # Add prefix for NewRelic
        metric = "#{prefix}/#{metric}" unless metric.start_with?(prefix)
        metric
      end

      def log(log)
        name = formatter.call(log, self)
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
        # Does not support metrics with dimensions.
        log.metric && !log.dimensions && meets_log_level?(log) && !filtered?(log)
      end
    end
  end
end
