require "uri"
begin
  require "statsd-ruby"
rescue LoadError
  raise LoadError, 'Gem statsd-ruby is required for logging metrics. Please add the gem "statsd-ruby" to your Gemfile.'
end

module SemanticLogger
  module Metric
    class Statsd < Subscriber
      attr_accessor :url

      # Create Statsd metrics subscriber
      #
      # Parameters:
      #   url: [String]
      #     Valid URL to post to.
      #     Example:
      #       udp://localhost:8125
      #     Example, send all metrics to a particular namespace:
      #       udp://localhost:8125/namespace
      #     Default: udp://localhost:8125
      #
      # Example:
      #   SemanticLogger.add_appender(
      #     metric: :statsd,
      #     url:    'localhost:8125'
      #   )
      def initialize(url: "udp://localhost:8125")
        @url = url
        super()
      end

      def reopen
        uri = URI.parse(@url)
        raise('Statsd only supports udp. Example: "udp://localhost:8125"') if uri.scheme != "udp"

        @statsd           = ::Statsd.new(uri.host, uri.port)
        path              = uri.path.chomp("/")
        @statsd.namespace = path.sub("/", "") if path != ""
      end

      def log(log)
        metric = log.metric
        if (duration = log.duration)
          @statsd.timing(metric, duration)
        else
          amount = (log.metric_amount || 1).round
          if amount.negative?
            amount.times { @statsd.decrement(metric) }
          else
            amount.times { @statsd.increment(metric) }
          end
        end
      end

      # Only forward log entries that contain metrics.
      def should_log?(log)
        # Does not support metrics with dimensions.
        log.metric && !log.dimensions && meets_log_level?(log) && !filtered?(log)
      end
    end
  end
end
