require 'json'
module SemanticLogger
  module Formatters
    class Signalfx < Base

      attr_accessor :token, :include_dimensions, :exclude_dimensions,
                    :hash, :log, :logger

      def initialize(token:,
                     include_dimensions: nil,
                     exclude_dimensions: nil,
                     log_host: true,
                     log_application: true)

        raise(ArgumentError, 'Cannot supply both :include_dimensions and :exclude_dimensions') if include_dimensions && exclude_dimensions

        @token              = token
        @include_dimensions = include_dimensions.map(&:to_sym) if include_dimensions
        @exclude_dimensions = exclude_dimensions.map(&:to_sym) if exclude_dimensions

        super(time_format: :ms, log_host: log_host, log_application: log_application)
      end

      # Create SignalFx friendly metric.
      #   Strip leading '/'
      #   Convert remaining '/' to '.'
      def metric
        name = log.metric.sub(/\A\/+/, '')
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
          if exclude_dimensions
            dimensions[name] = value unless exclude_dimensions.include?(name)
          else
            dimensions[name] = value if include_dimensions.include?(name)
          end
        end
        hash[:dimensions] = dimensions
      end

      # Returns log messages in Hash format
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

    end
  end
end
