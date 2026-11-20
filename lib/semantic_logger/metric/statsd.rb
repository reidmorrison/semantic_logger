require "uri"
begin
  require "statsd-ruby"
rescue LoadError
  raise LoadError, 'Gem statsd-ruby is required for logging metrics. Please add the gem "statsd-ruby" to your Gemfile.'
end

module SemanticLogger
  module Metric
    # Sends the metrics of each interval to a StatsD server over UDP.
    #
    # Counters: one count packet per metric name, `name:amount|c`, with the amount of the interval
    # rounded to an Integer, since StatsD counters are Integers. Nothing is sent for a zero amount.
    #
    # Histograms: StatsD has no histogram type, so a histogram is sent as one timer packet per
    # non-empty bucket, `name:midpoint|ms|@rate`, with the bucket's midpoint as the value and
    # 1 / the bucket's count as the sample rate, so that a StatsD server weights it as that many
    # timings (the Datadog agent and Telegraf do; etsy statsd counts them, but leaves the rate out of
    # its percentiles). A bucket with a count of 1 has no sample rate. Durations, recorded in seconds,
    # are sent in milliseconds, as StatsD timers are; any other histogram is sent in its own unit.
    #
    # statsd-ruby has no tags, so the series of a metric name that differ only by their dimensions are
    # added together (counters) or merged (histograms), and the name is sent once per interval.
    class Statsd < Subscriber
      include Snapshots

      # Builds and sends the lines of StatsD packets, as many in each UDP datagram as fit in DATAGRAM_SIZE
      # bytes, with the namespace of the Statsd client it sends them with.
      #
      # Unlike the statsd-ruby client's own methods, it sends every line it is given: the client samples
      # a packet that has a sample rate, sending it only when `rand < sample_rate`, which would drop most
      # of the bucket packets, whose sample rate only tells the server how many timings each one stands for.
      class Datagrams < ::Statsd::Batch
        # Largest UDP payload that fits in an Ethernet frame, without fragmenting, over IPv4 or IPv6.
        DATAGRAM_SIZE = 1432

        # Significant digits of a timer value: the buckets of a histogram are about 9% wide, so more
        # digits only lengthen the packets.
        SIGNIFICANT_DIGITS = 6

        # Significant digits of a sample rate.
        RATE_DIGITS = 10

        def initialize(statsd)
          super
          @batch_size      = nil
          @batch_byte_size = DATAGRAM_SIZE
          @flush_interval  = nil
        end

        # Adds a count packet: `name:amount|c`.
        def counter(name, amount)
          add("#{stat(name)}:#{amount}|c")
        end

        # Adds a timer packet standing for `count` timings of `value`: `name:value|ms|@rate`, the sample rate being
        # 1 / count, and left out for a count of 1.
        def timer(name, value, count)
          add("#{stat(name)}:#{number(value)}|ms#{"|@#{rate(count)}" unless count == 1}")
        end

        private

        # Sends the line in the datagram being filled, sending that datagram first when the line does not fit.
        def add(line)
          send_to_socket(line)
        end

        # The name with the namespace of the client, with its reserved characters replaced as the client does.
        def stat(name)
          "#{prefix}#{name.to_s.gsub('::', delimiter).tr(':|@', '_')}#{postfix}"
        end

        # A Float with SIGNIFICANT_DIGITS digits, without a trailing ".0".
        def number(value)
          return "0" if value.zero?

          digits = SIGNIFICANT_DIGITS - 1 - Math.log10(value.abs).floor
          value.round(digits).to_s.delete_suffix(".0")
        end

        # The sample rate for `count` timings: 1 / count with RATE_DIGITS significant digits, rounded down, and lowered
        # further when needed, so that 1 / rate is never below the count, since Telegraf truncates it to an Integer.
        def rate(count)
          places = count.to_s.length + RATE_DIGITS - 1
          digits = (10**places) / count
          text   = decimal(digits, places)
          text   = decimal(digits - 1, places) if 1.0 / Float(text) < count
          text
        end

        # `digits` / 10**places as a decimal fraction, without trailing zeros.
        def decimal(digits, places)
          "0.#{digits.to_s.rjust(places, '0')}".sub(/0+\z/, "")
        end
      end

      attr_accessor :url

      # Create Statsd metrics subscriber
      #
      # Parameters:
      #   url: [String]
      #     Url of the Statsd server to send metrics to. Only udp is supported.
      #     Example:
      #       udp://localhost:8125
      #     Example, send all metrics to a particular namespace:
      #       udp://localhost:8125/namespace
      #     Default: udp://localhost:8125
      #
      #   interval: [Numeric]
      #     Seconds between the metrics it sends.
      #     Default: 60
      #
      #   internal_metrics: [true|false]
      #     Whether to send Semantic Logger's own metrics too.
      #     Default: false
      #
      # Example:
      #   SemanticLogger.add_appender(
      #     metric:   :statsd,
      #     url:      'udp://localhost:8125',
      #     interval: 10
      #   )
      def initialize(url: "udp://localhost:8125", **args, &)
        @url = url
        super(**args, &)
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

      # Sends the counters and histograms of the snapshot, those of a metric name, whatever their dimensions,
      # together.
      def write_metrics(snapshot)
        datagrams = Datagrams.new(@statsd)
        by_name(snapshot).each_value do |point|
          if point.counter?
            send_counter(datagrams, point)
          else
            send_histogram(datagrams, point)
          end
        end
      ensure
        datagrams&.flush
      end

      # The url without any credentials. See Subscriber#inspect.
      def inspect_details
        "url=#{Utils.redacted_url(url).inspect}"
      end

      private

      # The points of the snapshot, those of a series that differ only by their dimensions merged into one.
      def by_name(snapshot)
        points = {}
        snapshot.each do |point|
          key         = [point.kind, point.name, point.unit]
          points[key] = points.key?(key) ? points[key].merge(point) : point
        end
        points
      end

      # A single counter packet, whatever the size of the amount.
      def send_counter(datagrams, point)
        amount = point.value
        # Infinity and NaN cannot be counted, whether a Float or a BigDecimal.
        return if amount.respond_to?(:finite?) && !amount.finite?

        amount = amount.round
        datagrams.counter(point.name, amount) unless amount.zero?
      end

      # One timer packet per non-empty bucket, at the bucket's midpoint, in milliseconds for a duration.
      def send_histogram(datagrams, point)
        scale = point.unit == "s" ? 1000.0 : 1.0
        point.value.each_bucket do |lower, upper, count|
          datagrams.timer(point.name, (lower + upper) / 2.0 * scale, count)
        end
      end
    end
  end
end
