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
      #     url:    'udp://localhost:8125'
      #   )
      def initialize(url: "udp://localhost:8125")
        @url = url
        super()
        reopen
      end

      # Creates the Statsd client, or reconnects it, such as in a forked process, which closes the socket that the
      # client had, rather than leaving it open. The host is resolved first, so that a failure to resolve it leaves the
      # client connected as it was. Only a url that drops the namespace creates a new client, since a client cannot be
      # given back no namespace, which leaves the old client's socket for garbage collection to close.
      def reopen
        uri = Utils.parse_url(@url)
        raise('Statsd only supports udp. Example: "udp://localhost:8125"') if uri.scheme != "udp"

        # The host without the brackets of an IPv6 address.
        host      = uri.hostname
        path      = uri.path.chomp("/")
        namespace = path.sub("/", "") unless path == ""
        if @statsd && (namespace || @statsd.namespace.nil?)
          Addrinfo.ip(host)
          @statsd.host      = host
          @statsd.port      = uri.port
          @statsd.namespace = namespace if namespace
          @statsd.connect
        else
          @statsd           = ::Statsd.new(host, uri.port)
          @statsd.namespace = namespace if namespace
        end
      end

      def log(log)
        metric = log.metric
        if (duration = log.duration)
          @statsd.timing(metric, duration)
        else
          amount = log.metric_amount || 1
          # Infinity and NaN cannot be counted, whether a Float or a BigDecimal.
          return if amount.respond_to?(:finite?) && !amount.finite?

          amount = amount.round
          # A single counter packet, whatever the size of the amount. Incrementing once per unit
          # would let a large amount, such as one supplied by a user, flood the network and
          # stall the logging thread.
          @statsd.count(metric, amount) unless amount.zero?
        end
      end

      # Only forward log entries that contain metrics.
      def should_log?(log)
        # Does not support metrics with dimensions.
        log.metric && !log.dimensions && meets_log_level?(log) && !filtered?(log)
      end

      # The url without any credentials. See Subscriber#inspect.
      def inspect_details
        "url=#{Utils.redacted_url(url).inspect}"
      end
    end
  end
end
