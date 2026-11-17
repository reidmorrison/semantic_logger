require "json"
module SemanticLogger
  module Formatters
    class Signalfx < Base
      attr_accessor :token, :dimensions, :hash, :gauge_name, :counter_name

      def initialize(token:,
                     dimensions: nil,
                     gauge_name: "Application.average",
                     counter_name: "Application.counter",
                     time_format: :ms,
                     **args)
        @token        = token
        @dimensions   = dimensions.map(&:to_sym) if dimensions
        @gauge_name   = gauge_name
        @counter_name = counter_name

        super(time_format: time_format, **args)
      end

      # Create SignalFx friendly metric.
      #   Strip leading '/'
      #   Convert remaining '/' to '.'
      # A name that is not valid UTF-8, such as one with invalid bytes or in UTF-16, which matching
      # it raises for, is converted to valid UTF-8 first (see Utils.encode_utf8_string).
      #
      # A metric with dimensions that are not blank (see #present_dimensions) is sent under its own name.
      # Any other is sent as the gauge or the counter, with the class and action taken from its name.
      def metric
        name = Utils.encode_utf8_string(log.metric.to_s).sub(%r{\A/+}, "")
        if metric_dimensions
          name.tr!("/", ".")
          hash[:metric] = name
        else
          # Extract class and action from metric name
          names = name.split("/")
          h     = (hash[:dimensions] ||= {})
          if names.size > 1
            h[:action] = names.pop
            h[:class]  = names.join("::")
          else
            h[:class]  = "Unknown"
            h[:action] = names.first || log.metric
          end

          hash[:metric] = log.duration ? gauge_name : counter_name
        end
      end

      # Date & time
      def time
        # 1 second resolution, represented as ms.
        hash[:timestamp] = log.time.to_i * 1000
      end

      # Value of this metric
      def value
        hash[:value] = log.metric_amount || log.duration || 1
      end

      # Dimensions for this metric: those of the log entry that are not blank, or when it has none, the
      # named tags listed in the dimensions option whose values are not blank (see #blank_value?).
      def format_dimensions
        h = (hash[:dimensions] ||= {})
        if metric_dimensions
          h.merge!(metric_dimensions)
        else
          log.named_tags.each_pair do |name, value|
            name  = name.to_sym
            value = value.to_s
            next if blank_value?(value)

            h[name] = value if dimensions&.include?(name)
          end
        end
        h[:host]        = logger.host if log_host && logger.host
        h[:application] = logger.application if log_application && logger.application
        h[:environment] = logger.environment if log_environment && logger.environment
      end

      # Returns [Hash] log message in Signalfx format.
      def call(log, logger)
        self.hash   = {}
        self.log    = log
        self.logger = logger

        metric
        time
        value
        format_dimensions

        # gauge, counter, or cumulative_counter
        data = {}
        if log.duration
          data[:gauge] = [hash]
          # Also send a count metric whenever it is a gauge so that it can be counted.
          unless metric_dimensions
            count_hash          = hash.dup
            count_hash[:value]  = log.metric_amount || 1
            count_hash[:metric] = counter_name
            data[:counter]      = [count_hash]
          end
        else
          data[:counter] = [hash]
        end

        Utils.to_json(data)
      end

      # Returns [Hash] a batch of log messages.
      # Signalfx has a minimum resolution of 1 second.
      # Metrics of the same type, time (second), and dimensions can be aggregated together.
      def batch(logs, logger)
        self.logger = logger

        data = {}
        logs.each do |log|
          self.hash = {}
          self.log  = log

          metric
          time
          value
          format_dimensions

          if log.duration
            gauges = (data[:gauge] ||= [])
            add_gauge(gauges, hash)

            # Also send a count metric whenever it is a gauge so that it can be counted.
            unless metric_dimensions
              count_hash          = hash.dup
              count_hash[:value]  = log.metric_amount || 1
              count_hash[:metric] = counter_name
              counters            = (data[:counter] ||= [])
              add_counter(counters, count_hash)
            end
          else
            counters = (data[:counter] ||= [])
            add_counter(counters, hash)
          end
        end

        Utils.to_json(data)
      end

      # The log entry to format. Also keeps the dimensions of its metric that are sent (see
      # #present_dimensions), which formatting the entry asks for several times.
      def log=(log)
        super
        @metric_dimensions = log && present_dimensions
      end

      private

      # The dimensions of the entry's metric that are sent, or nil when there are none.
      attr_reader :metric_dimensions

      # Returns [Hash] the dimensions of the entry's metric, as Log#dimensions? tells, with each value as
      # text, leaving out those that are blank (see #blank_value?). Returns nil when there are none, or only
      # blank ones, such as `{state: ""}`, so that the metric is sent as a metric without dimensions is:
      # as the gauge or the counter, with the class and action taken from its name. Log#dimensions?
      # counts such dimensions, which the formatters that write the entry's data write as they are.
      def present_dimensions
        return unless log.dimensions?

        present = {}
        log.dimensions.each_pair do |name, value|
          value         = value.to_s
          present[name] = value unless blank_value?(value)
        end
        present unless present.empty?
      end

      # Returns [true|false] whether the text of a dimension value is blank: empty, as for nil, or only
      # whitespace. Text that is not valid UTF-8, which String#strip raises for, is converted first.
      def blank_value?(text) = Utils.encode_utf8_string(text).strip.empty?

      def add_gauge(gauges, metric)
        gauges << metric
      end

      # Sum counters with the same time (second), name, and dimensions.
      def add_counter(counters, metric)
        existing = find_match(counters, metric)
        existing ? existing[:value] += metric[:value] : counters << metric
      end

      # Find Metrics with the same timestamp, metric name, and dimensions.
      def find_match(list, metric)
        list.find do |item|
          (item[:timestamp] == metric[:timestamp]) &&
            (item[:metric] == metric[:metric]) &&
            (item[:dimensions] == metric[:dimensions])
        end
      end
    end
  end
end
