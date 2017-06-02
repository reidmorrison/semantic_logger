require 'json'
module SemanticLogger
  module Formatters
    class Signalfx < Base

      attr_accessor :token, :include_dimensions, :hash, :log, :logger

      def initialize(token:,
                     include_dimensions: nil,
                     log_host: true,
                     log_application: true)

        @token              = token
        @include_dimensions = include_dimensions.map(&:to_sym) if include_dimensions

        super(time_format: :ms, log_host: log_host, log_application: log_application)
      end

      # Create SignalFx friendly metric.
      #   Strip leading '/'
      #   Convert remaining '/' to '.'
      def metric
        name = log.metric.to_s.sub(/\A\/+/, '')
        name.gsub!('/', '.')
        hash[:metric] = name
      end

      # Date & time
      def time
        hash[:timestamp] = format_time(log.time)
      end

      # Value of this metric
      def value
        hash[:value] = log.metric_amount || log.duration || 1
      end

      # Dimensions for this metric
      def dimensions
        return unless log.named_tags && !log.named_tags.empty?

        dimensions               = {}
        dimensions[:host]        = logger.host if log_host && logger.host
        dimensions[:application] = logger.application if log_application && logger.application

        log.named_tags.each_pair do |name, value|
          name  = name.to_sym
          value = value.to_s
          next if value.empty?
          dimensions[name] = value if include_dimensions.include?(name)
        end
        hash[:dimensions] = dimensions unless dimensions.empty?
      end

      # Returns [Hash] log message in Signalfx format.
      def call(log, logger)
        self.hash   = {}
        self.log    = log
        self.logger = logger

        metric; time; value; dimensions

        # gauge, counter, or cumulative_counter
        data = {}
        if log.duration
          data[:gauge] = [hash]
        else
          data[:counter] = [hash]
        end
        data.to_json
      end

      # Returns [Hash] a batch of log messages.
      def batch(logs, logger)
        self.logger = logger

        data = {}
        logs.each do |log|
          self.hash = {}
          self.log  = log

          metric; time; value; dimensions

          if log.duration
            (data[:gauge] ||= []) << hash
          else
            counters = (data[:counter] ||= [])
            # Aggregate counters with the same name, using the timestamp of the first entry in this poll interval.
            if existing = counters.find { |counter| counter[:metric] == hash[:metric] }
              existing.value += hash[:value]
            else
              counters << hash
            end
          end
        end
        data.to_json
      end

    end
  end
end
