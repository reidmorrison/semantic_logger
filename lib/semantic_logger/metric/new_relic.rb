begin
  require "newrelic_rpm"
rescue LoadError
  raise LoadError,
        'Gem newrelic_rpm is required for logging to New Relic. Please add the gem "newrelic_rpm" to your Gemfile.'
end

# Send Metrics to NewRelic
#
# Records the metrics of each interval as New Relic custom metrics, through the agent's metric API:
#   - a counter with increment_metric, by the sum of its amounts;
#   - a histogram with record_metric, as one pre-aggregated value: its count, total, min, max, and
#     sum of squares. Durations are in seconds, as New Relic expects.
#
# New Relic metric names have no dimensions, so the series of a metric with dimensions are merged,
# and recorded under its name alone, once per interval.
#
# Example:
#   SemanticLogger.add_appender(metric: :new_relic)
module SemanticLogger
  module Metric
    class NewRelic < SemanticLogger::Subscriber
      include Snapshots

      attr_reader :prefix

      # Create the New Relic metrics subscriber
      #
      # Parameters
      #   prefix: [String]
      #     Prefix to add, with a `/`, to every metric name that does not already start with it and
      #     a `/`, before forwarding to NewRelic, which charts custom metrics only under `Custom/`.
      #     So 'Customers/signup' is recorded as 'Custom/Customers/signup', and 'Custom/Orders/placed'
      #     as it is. Another prefix should start with `Custom/` too, such as 'Custom/MyApp'. A
      #     trailing `/` is left out, and an empty prefix adds nothing.
      #     Default: 'Custom'
      #
      #   interval: [Numeric]
      #     Seconds between the metrics it records.
      #     Default: 60
      #
      #   internal_metrics: [true|false]
      #     Whether to record Semantic Logger's own metrics too.
      #     Default: false
      def initialize(prefix: "Custom", **args, &)
        self.prefix = prefix
        @warned     = {}
        super(**args, &)
      end

      # Sets the prefix that is added to metric names, without a trailing `/`, since one is added with
      # it. An empty prefix is added as an empty String, which every name already starts with.
      def prefix=(prefix)
        @prefix            = prefix.to_s.delete_suffix("/")
        @prefix_with_slash = @prefix.empty? ? "" : "#{@prefix}/"
      end

      # Records the points of the snapshot, those with the same New Relic name merged into one (see
      # Snapshot#merged_by), without empty histograms.
      def write_metrics(snapshot)
        snapshot.merged_by { |point| metric_name(point.name) }.each do |name, (kind, _unit, value)|
          if kind == :counter
            increment(name, value)
          elsif !value.empty?
            record(name, value)
          end
        end
        true
      end

      # Largest count that New Relic keeps exactly: a counter sum above it is recorded as a Float.
      MAX_COUNT = (2**63) - 1

      # Most metric names that it warns about, each once, for values beyond the range of a Float.
      WARNINGS_LIMIT = 1000

      private

      # Returns the name with the prefix, unless it already starts with it.
      def metric_name(name)
        name = name.to_s
        return name if name.start_with?(@prefix_with_slash)

        "#{@prefix_with_slash}#{name}"
      end

      # Increments the counter by the amount, as a Float when it is too large for New Relic to keep as an
      # Integer, unless it is not finite, which New Relic cannot send.
      def increment(name, amount)
        amount = amount.to_f if amount.is_a?(Integer) && amount.abs > MAX_COUNT
        return not_finite(name) if amount.respond_to?(:finite?) && !amount.finite?

        ::NewRelic::Agent.increment_metric(name, amount)
      end

      # Records the histogram as the pre-aggregated value that NewRelic::Agent.record_metric takes, its sum
      # of squares estimated by the histogram, unless its total is not finite, which New Relic cannot send. A
      # sum of squares beyond the range of a Float is recorded as Float::MAX, so that its count, total, min
      # and max are still recorded.
      def record(name, histogram)
        total = histogram.sum
        return not_finite(name) unless total.finite?

        sum_of_squares = histogram.sum_of_squares
        sum_of_squares = Float::MAX unless sum_of_squares.finite?
        ::NewRelic::Agent.record_metric(
          name,
          {count: histogram.count, total: total, min: histogram.min, max: histogram.max, sum_of_squares: sum_of_squares}
        )
      end

      # Warns once for each name, up to WARNINGS_LIMIT names, so that a name that goes on adding up beyond
      # the range of a Float does not warn at every interval. Called holding the lock of the snapshots (see
      # Metric::Snapshots).
      def not_finite(name)
        return if @warned.key?(name) || @warned.size >= WARNINGS_LIMIT

        @warned[name] = true
        logger.warn(
          "Left out the metric #{name.inspect} of this interval: its values add up beyond the range of a Float. " \
          "Further intervals of it are left out without a warning."
        )
      end
    end
  end
end
