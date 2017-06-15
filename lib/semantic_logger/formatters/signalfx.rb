require 'json'
module SemanticLogger
  module Formatters
    class Signalfx < Base
      attr_accessor :token, :dimensions, :hash, :log, :logger, :metric_name, :environment

      def initialize(token:,
                     dimensions: nil,
                     log_host: true,
                     log_application: true,
                     metric_name: 'Application.average',
                     environment: true)

        @token       = token
        @dimensions  = dimensions.map(&:to_sym) if dimensions
        @metric_name = metric_name

        if environment == true
          @environment = defined?(Rails) ? Rails.env : ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
        elsif environment
          @environment = environment
        end

        super(time_format: :ms, log_host: log_host, log_application: log_application)
      end

      # Create SignalFx friendly metric.
      #   Strip leading '/'
      #   Convert remaining '/' to '.'
      def metric
        if log.dimensions
          name = log.metric.to_s.sub(/\A\/+/, '')
          name.gsub!('/', '.')
          hash[:metric] = name
        else
          hash[:metric] = metric_name
        end
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
      def format_dimensions
        h = {}
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
            h[name] = value if dimensions && dimensions.include?(name)
          end
          # Extract class and action from metric name
          names = log.metric.split('/')
          if names.size > 1
            h[:action] = names.pop
            h[:class]  = names.join('::')
          else
            h[:class]  = 'Unknown'
            h[:action] = names.first || log.metric
          end
        end
        h[:host]          = logger.host if log_host && logger.host
        h[:application]   = logger.application if log_application && logger.application
        h[:environment]   = environment if environment

        hash[:dimensions] = h unless h.empty?
      end

      # Returns [Hash] log message in Signalfx format.
      def call(log, logger)
        self.hash   = {}
        self.log    = log
        self.logger = logger

        metric; time; value; format_dimensions

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

          metric; time; value; format_dimensions

          if log.duration
            (data[:gauge] ||= []) << hash
          else
            counters = (data[:counter] ||= [])
            # Aggregate counters with the same name, using the timestamp of the first entry in this poll interval.
            if existing = counters.find { |counter| (counter[:metric] == hash[:metric]) && (counter[:dimensions] == hash[:dimensions]) }
              existing[:value] += hash[:value]
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
