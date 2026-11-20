module SemanticLogger
  module Metric
    # Writes the metrics of each interval as log entries, one for each series, so that every log
    # appender, such as a file, $stdout, or a JSON log service, writes them with its own formatter.
    #
    #   SemanticLogger.add_appender(metric: :summary)
    #   SemanticLogger.add_appender(metric: :summary, interval: 300, level: :debug)
    #
    # Each entry is named after this class, its message is the name of the metric, and its payload
    # holds the values of the series over the interval:
    #
    #   counter:   {sum: 12}
    #   histogram: {count: 1204, sum: 98.1, min: 0.012, max: 2.7, p50: 0.061, p95: 0.24, p99: 0.81, unit: "s"}
    #
    # The payload also holds the unit of a counter that has one, and `dimensions:` for a series that has
    # any. Sums, minimums, maximums, and the estimated percentiles are rounded to 3 significant digits,
    # keeping every digit before the decimal point. A percentile is an estimate, made within the bucket
    # of the histogram that holds it (see ExponentialHistogram#quantile).
    #
    # It knows the level of the entries that it writes, :info unless given, which is its own fallback
    # level (see #fallback_level), rather than the :trace of other appenders, and writes them through
    # the processor (see Processor#log_aside), never waiting for it: it writes them on the processor's
    # own thread, or, when added with async: true, on a thread that the processor's thread may be
    # waiting for. It takes no log entries itself, and its entries carry no metric, nor the tags or
    # named tags of the thread that writes them, which belong to whatever that thread was doing.
    class Summary < Subscriber
      include Snapshots

      # Significant digits of the sums, minimums, maximums, and percentiles that it writes.
      SIGNIFICANT_DIGITS = 3

      # The percentiles that it writes for a histogram, by payload key.
      PERCENTILES = {p50: 0.5, p95: 0.95, p99: 0.99}.freeze

      # The level index of :info, its fallback level.
      INFO_INDEX = Levels.index(:info)
      private_constant :INFO_INDEX

      # Parameters:
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Level of the log entries that it writes. Each log appender writes those at or above its
      #     own level.
      #     Default: :info, also when nil
      #
      #   interval: [Numeric]
      #     Seconds between the summaries that it writes.
      #     Default: 60
      #
      #   internal_metrics: [true|false]
      #     Whether to write Semantic Logger's own metrics too.
      #     Default: false
      def initialize(level: nil, **args, &)
        super
      end

      # Writes one log entry for each point of the snapshot, handing them all to the processor at once,
      # in order.
      def write_metrics(snapshot)
        logs = snapshot.map { |point| entry(point) }
        Logger.processor.log_aside(logs) unless logs.empty?
        true
      end

      private

      # Takes level:, the level of the log entries that it writes, which other metric appenders refuse.
      def refused_log_entry_options = super - [:level]

      # Returns [Log] the log entry for the point, without the tags or named tags of the thread that
      # writes it.
      def entry(point)
        log            = Log.new(name, level)
        log.tags       = []
        log.named_tags = {}
        log.assign(message: point.name, payload: payload(point))
        log
      end

      # The level of its entries when it is given none, rather than the :trace of other appenders
      # (see Subscriber#fallback_level).
      def fallback_level = :info

      # The index of #fallback_level, for the comparisons that use the index.
      def fallback_level_index = INFO_INDEX

      def payload(point)
        payload              = point.counter? ? {sum: rounded(point.value)} : histogram_payload(point.value)
        payload[:unit]       = point.unit if point.unit
        payload[:dimensions] = point.dimensions unless point.dimensions.empty?
        payload
      end

      def histogram_payload(histogram)
        payload = {
          count: histogram.count,
          sum:   rounded(histogram.sum),
          min:   rounded(histogram.min),
          max:   rounded(histogram.max)
        }
        PERCENTILES.each_pair { |key, probability| payload[key] = rounded(histogram.quantile(probability)) }
        payload
      end

      # Returns the value rounded to SIGNIFICANT_DIGITS, keeping every digit before the decimal point: an
      # Integer once no digit after it is left. An Integer, zero, or a value that is not finite is returned
      # as it is.
      def rounded(value)
        return value unless value.is_a?(Float) && value.finite? && !value.zero?

        digits = SIGNIFICANT_DIGITS - 1 - Math.log10(value.abs).floor
        digits.positive? ? value.round(digits) : value.round
      end
    end
  end
end
