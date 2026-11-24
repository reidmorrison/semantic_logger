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
    # rounded to an Integer, since StatsD counters are Integers, the fraction left over added to the
    # amount of the next interval, when the name has one. Nothing is sent for a zero amount.
    #
    # Histograms: StatsD has no histogram type, so a histogram is sent as one timer packet per
    # non-empty bucket, `name:midpoint|ms|@rate`, with the bucket's midpoint as the value and
    # 1 / the bucket's count as the sample rate, so that a StatsD server weights it as that many
    # timings (the Datadog agent and Telegraf do; etsy statsd counts them, but leaves the rate out of
    # its percentiles). A bucket with a count of 1 has no sample rate. Durations, recorded in seconds,
    # are sent in milliseconds, as StatsD timers are; any other histogram is sent in its own unit.
    #
    # statsd-ruby has no tags, so the series of a metric name that differ only by their dimensions are
    # added together (counters) or merged (histograms), and the name is sent once per interval. A line
    # break, or a character that is not ASCII, in a name is sent as "_".
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
          @stats           = {}
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

        # The name with the namespace of the client, with its reserved characters replaced as the client does,
        # and with each line break, and each character that is not ASCII, replaced with "_" too: a line break
        # would split the packet in two, and statsd-ruby takes a datagram as sent only when the socket wrote as
        # many bytes as it has characters, otherwise sending it again, up to 5 times. StatsD servers take ASCII
        # names.
        #
        # The name is made ASCII first, so that a name in any encoding, or with invalid bytes, can be replaced
        # in. Built once for each name of the datagrams.
        def stat(name)
          @stats[name] ||= "#{prefix}#{ascii(name.to_s).gsub('::', delimiter).tr(":|@\r\n", '_')}#{postfix}"
        end

        # The name in US-ASCII, each character that is not ASCII, and each invalid byte, replaced with "_".
        def ascii(name)
          return name if name.ascii_only? && name.encoding.ascii_compatible?

          name.encode(Encoding::US_ASCII, invalid: :replace, undef: :replace, replace: "_")
        end

        # A finite Float with SIGNIFICANT_DIGITS significant digits, in fixed-point notation, since StatsD
        # servers do not all read an exponent, without trailing zeros.
        def number(value)
          return "0" if value.zero?

          digits = SIGNIFICANT_DIGITS - 1 - Math.log10(value.abs).floor
          text   = format("%.*f", digits.clamp(0, nil), value.round(digits))
          text.include?(".") ? text.sub(/\.?0+\z/, "") : text
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
        @url        = url
        @remainders = {}
        super(**args, &)
        reopen
      end

      # Creates the Statsd client, or reconnects it, such as in a forked process, which closes the socket that the
      # client had, rather than leaving it open. The host is resolved first, so that a failure to resolve it leaves the
      # client connected as it was. Only a url that drops the namespace creates a new client, since a client cannot be
      # given back no namespace, which leaves the old client's socket for garbage collection to close.
      #
      # Calls Metric::Snapshots#reopen first, which discards the snapshots inherited by a forked child.
      def reopen
        super
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
      # together (see Snapshot#merged_by). Sends the last datagram only once every packet is in one, so that
      # a failure sends none of the rest.
      #
      # Carries the fraction left over by rounding each counter to its next interval once the snapshot is
      # sent, forgetting those of the names it does not hold, so that they cannot grow without bound. When
      # sending fails, it carries those it carried before.
      def write_metrics(snapshot)
        datagrams  = Datagrams.new(@statsd)
        remainders = {}
        snapshot.merged_by(&:name).each do |name, (kind, unit, value)|
          if kind == :counter
            send_counter(datagrams, name, value, remainders)
          else
            send_histogram(datagrams, name, unit, value)
          end
        end
        datagrams.flush
        @remainders = remainders
      end

      # The url without any credentials. See Subscriber#inspect.
      def inspect_details
        "url=#{Utils.redacted_url(url).inspect}"
      end

      private

      # A single counter packet, whatever the size of the amount, rounded to an Integer, the fraction left
      # over kept in `remainders`, to add to its next amount, so that fractional amounts add up over the
      # intervals.
      def send_counter(datagrams, name, amount, remainders)
        # Infinity and NaN cannot be counted, whether a Float or a BigDecimal.
        return if amount.respond_to?(:finite?) && !amount.finite?

        amount   += @remainders.fetch(name, 0)
        rounded   = amount.round
        remainder = amount - rounded
        remainders[name] = remainder unless remainder.zero?
        datagrams.counter(name, rounded) unless rounded.zero?
      end

      # One timer packet per non-empty bucket, at the bucket's midpoint, in milliseconds for a duration,
      # leaving out a bucket whose midpoint in milliseconds is beyond the range of a Float.
      def send_histogram(datagrams, name, unit, histogram)
        scale = unit == "s" ? 1000.0 : 1.0
        histogram.each_bucket do |lower, upper, count|
          value = (lower + ((upper - lower) / 2.0)) * scale
          datagrams.timer(name, value, count) if value.finite?
        end
      end

      # In a forked child, forgets the fractions of the counters left over in the parent, which carries them
      # itself (see Metric::Snapshots#forget_parent_state).
      def forget_parent_state
        @remainders = {}
      end
    end
  end
end
