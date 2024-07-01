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
      def metric
        name = log.metric.to_s.sub(%r{\A/+}, "")
        if log.dimensions
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

      # Dimensions for this metric
      def format_dimensions
        h = (hash[:dimensions] ||= {})
        if log.dimensions
          log.dimensions.each_pair do |name, value|
            value   = value.to_s
            h[name] = value unless value.empty?
          end
        else
          log.named_tags.each_pair do |name, value|
            name  = name.to_sym
            value = value.to_s
            next if value.empty?

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
          unless log.dimensions
            count_hash          = hash.dup
            count_hash[:value]  = log.metric_amount || 1
            count_hash[:metric] = counter_name
            data[:counter]      = [count_hash]
          end
        else
          data[:counter] = [hash]
        end

        data.to_json
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
            unless log.dimensions
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

        data.to_json
      end

      private

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
