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
        super(**args, &)
      end

      # Sets the prefix that is added to metric names, without a trailing `/`, since one is added with
      # it. An empty prefix is added as an empty String, which every name already starts with.
      def prefix=(prefix)
        @prefix            = prefix.to_s.delete_suffix("/")
        @prefix_with_slash = @prefix.empty? ? "" : "#{@prefix}/"
      end

      # Records the points of the snapshot, those with the same New Relic name and kind merged into one.
      def write_metrics(snapshot)
        merged_by_name(snapshot).each do |(kind, name), value|
          if kind == :counter
            ::NewRelic::Agent.increment_metric(name, value)
          else
            ::NewRelic::Agent.record_metric(name, aggregate(value))
          end
        end
        true
      end

      private

      # Returns [Hash] the value of each kind and New Relic name: the sum of its counters, or the merge of
      # its histograms, without empty histograms.
      def merged_by_name(snapshot)
        merged = {}
        snapshot.each do |point|
          value = point.value
          next if point.histogram? && value.empty?

          key         = [point.kind, metric_name(point.name)]
          earlier     = merged[key]
          merged[key] =
            if earlier.nil?
              value
            elsif point.counter?
              earlier + value
            else
              (earlier.frozen? ? earlier.dup : earlier).merge(value)
            end
        end
        merged
      end

      # Returns the name with the prefix, unless it already starts with it.
      def metric_name(name)
        name = name.to_s
        return name if name.start_with?(@prefix_with_slash)

        "#{@prefix_with_slash}#{name}"
      end

      # Returns [Hash] the histogram as the pre-aggregated value that NewRelic::Agent.record_metric takes.
      #
      # The sum of squares is estimated from the midpoint of each bucket, and is never less than the
      # sum of squares of `count` values equal to their mean, so that the variance it implies is not negative.
      def aggregate(histogram)
        count          = histogram.count
        total          = histogram.sum
        sum_of_squares = 0.0
        histogram.each_bucket do |lower, upper, bucket_count|
          midpoint        = (lower + upper) / 2.0
          sum_of_squares += bucket_count * midpoint * midpoint
        end
        least = total * total / count
        sum_of_squares = least if sum_of_squares < least
        {count: count, total: total, min: histogram.min, max: histogram.max, sum_of_squares: sum_of_squares}
      end
    end
  end
end
