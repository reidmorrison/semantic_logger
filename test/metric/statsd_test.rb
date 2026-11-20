require_relative "../test_helper"
require "bigdecimal"

module Metric
  class StatsdTest < Minitest::Test
    # Stands in for a statsd-ruby client.
    class FakeStatsd
      attr_accessor :namespace
    end

    describe SemanticLogger::Metric::Statsd do
      let(:server) do
        socket = UDPSocket.new
        socket.bind("127.0.0.1", 0)
        socket
      end
      let(:url) { "udp://127.0.0.1:#{server.addr[1]}" }
      let(:appender) { SemanticLogger::Metric::Statsd.new(url: url) }
      let(:aggregator) { SemanticLogger::Metric::Aggregator.new }

      after do
        server.close
      end

      # Returns [Array<String>] the datagrams received by the server, until none arrives for a moment.
      def datagrams
        received = []
        received << server.recv(65_535) while server.wait_readable(0.2)
        received
      end

      # Returns [Array<String>] the packets received by the server, one per line of each datagram.
      def packets
        datagrams.flat_map { |datagram| datagram.split("\n") }
      end

      # Writes what the aggregator recorded, and returns the packets received.
      def write
        appender.write_metrics(aggregator.collect)
        packets
      end

      # A snapshot holding the points.
      def snapshot(*points)
        SemanticLogger::Metric::Snapshot.new(start_time: Time.now - 60, end_time: Time.now, points: points)
      end

      def counter(name, value, **args)
        SemanticLogger::Metric::Snapshot::Point.new(kind: :counter, name: name, value: value, **args)
      end

      # The count of timings a timer packet stands for, as a StatsD server weights it.
      def weight(packet)
        rate = packet[/\|@(.*)\z/, 1]
        rate ? (1.0 / Float(rate)).floor : 1
      end

      describe "#initialize" do
        it "defaults to localhost udp" do
          assert_equal "udp://localhost:8125", SemanticLogger::Metric::Statsd.new.url
        end

        it "accepts a custom url" do
          assert_equal "udp://127.0.0.1:9125", SemanticLogger::Metric::Statsd.new(url: "udp://127.0.0.1:9125").url
        end

        it "raises when the scheme is not udp" do
          assert_raises(RuntimeError) { SemanticLogger::Metric::Statsd.new(url: "tcp://127.0.0.1:8125") }
        end

        it "connects to an IPv6 address without its brackets" do
          hosts = []
          ::Statsd.stub(:new, lambda { |host, _port|
            hosts << host
            FakeStatsd.new
          }) do
            SemanticLogger::Metric::Statsd.new(url: "udp://[::1]:8125")
          end

          assert_equal ["::1"], hosts
        end

        it "connects, so that it sends metrics without a reopen" do
          aggregator.record(:counter, "user/login", 1)

          assert_equal ["user/login:1|c"], write
        end

        it "sets the namespace from the url path" do
          subscriber = SemanticLogger::Metric::Statsd.new(url: "udp://127.0.0.1:8125/my_app")

          assert_equal "my_app", subscriber.instance_variable_get(:@statsd).namespace
        end

        it "leaves the namespace unset when no path is supplied" do
          subscriber = SemanticLogger::Metric::Statsd.new

          assert_nil subscriber.instance_variable_get(:@statsd).namespace
        end

        it "has an interval of 60 seconds by default" do
          assert_equal 60, appender.metrics_interval
        end

        it "accepts an interval" do
          assert_equal 10, SemanticLogger::Metric::Statsd.new(url: url, interval: 10).metrics_interval
        end

        {
          level:     "whatever the log level",
          filter:    "every metric recorded is written",
          formatter: "the format of its destination"
        }.each_pair do |option, replacement|
          it "refuses #{option}:, which was for the log entries it no longer takes" do
            error = assert_raises(ArgumentError) do
              SemanticLogger::Metric::Statsd.new(url: url, option => :info)
            end

            assert_includes error.message, "#{option}:"
            assert_includes error.message, replacement
          end
        end

        it "refuses a formatter block" do
          error = assert_raises(ArgumentError) do
            SemanticLogger::Metric::Statsd.new(url: url, &:name)
          end

          assert_includes error.message, "formatter block"
        end

        it "refuses batch: true" do
          error = assert_raises(ArgumentError) do
            SemanticLogger::Appender.factory(metric: :statsd, url: url, batch: true)
          end

          assert_includes error.message, "nothing to batch"
        end
      end

      describe "#reopen" do
        let(:subscriber) { SemanticLogger::Metric::Statsd.new(url: "udp://127.0.0.1:8125/my_app") }
        let(:client) { subscriber.instance_variable_get(:@statsd) }

        it "reconnects the client, which closes the socket it had" do
          connected = false
          client.stub(:connect, -> { connected = true }) { subscriber.reopen }

          assert connected
          assert_same client, subscriber.instance_variable_get(:@statsd)
        end

        it "reconnects the client to a new host and port, and namespace" do
          old_client     = client
          subscriber.url = "udp://127.0.0.2:9999/other_app"
          subscriber.reopen

          assert_same old_client, subscriber.instance_variable_get(:@statsd)
          assert_equal "127.0.0.2", old_client.host
          assert_equal 9999, old_client.port
          assert_equal "other_app", old_client.namespace
        end

        it "leaves the client connected when the host cannot be resolved" do
          connected = false
          client.stub(:connect, -> { connected = true }) do
            Addrinfo.stub(:ip, ->(_host) { raise SocketError, "getaddrinfo: no such host" }) do
              assert_raises(SocketError) { subscriber.reopen }
            end
          end

          refute connected
        end

        it "creates a new client when the url drops the namespace" do
          old_client     = client
          subscriber.url = "udp://127.0.0.1:8125"
          subscriber.reopen

          refute_same old_client, subscriber.instance_variable_get(:@statsd)
          assert_nil subscriber.instance_variable_get(:@statsd).namespace
        end
      end

      describe "log entries" do
        it "takes none" do
          log        = SemanticLogger::Log.new("StatsdTest", :info)
          log.metric = "user/login"

          refute appender.should_log?(log)
        end
      end

      describe "a counter" do
        it "is sent as one count packet for the interval" do
          3.times { aggregator.record(:counter, "user/login", 2) }

          assert_equal ["user/login:6|c"], write
        end

        it "is sent with the namespace of the url" do
          appender.url = "#{url}/my_app"
          appender.reopen
          aggregator.record(:counter, "user/login", 1)

          assert_equal ["my_app.user/login:1|c"], write
        end

        it "replaces the characters reserved by StatsD in its name, as statsd-ruby does" do
          aggregator.record(:counter, "Billing::user:login|x@y", 1)

          assert_equal ["Billing.user_login_x_y:1|c"], write
        end

        it "replaces a line break in its name, which would split the packet" do
          aggregator.record(:counter, "user\nlogin\r", 1)

          assert_equal ["user_login_:1|c"], write
        end

        it "replaces each character of its name that is not ASCII, sending the datagram once" do
          aggregator.record(:counter, "caf\u00e9.ma\u00f1ana", 1)
          appender.write_metrics(aggregator.collect)

          # statsd-ruby sends a datagram again, up to 5 times, unless the socket wrote as many bytes as it has
          # characters.
          assert_equal ["caf_.ma_ana:1|c"], datagrams
        end

        it "replaces each byte of a binary name that is not ASCII" do
          appender.write_metrics(snapshot(counter("caf\xC3\xA9".b, 1)))

          assert_equal ["caf__:1|c"], packets
        end

        it "replaces each invalid byte of a UTF-8 name, rather than raise" do
          appender.write_metrics(snapshot(counter("caf\xFF::login".dup.force_encoding(Encoding::UTF_8), 1)))

          assert_equal ["caf_.login:1|c"], packets
        end

        it "sends a name in an encoding that is not ASCII compatible as ASCII" do
          appender.write_metrics(snapshot(counter("Billing::caf\u00e9:login".encode(Encoding::UTF_16LE), 1)))

          assert_equal ["Billing.caf__login:1|c"], packets
        end

        it "builds the name to send once for each name" do
          built = []
          ascii = SemanticLogger::Metric::Statsd::Datagrams.instance_method(:ascii)
          spy   = lambda do |name|
            built << name
            ascii.bind_call(self, name)
          end
          [1, 2, 4, 8].each { |value| aggregator.record(:histogram, "order.items", value) }
          aggregator.record(:counter, "user/login", 1)

          SemanticLogger::Metric::Statsd::Datagrams.stub_any_instance(:ascii, spy) do
            assert_equal 5, write.size
          end

          assert_equal ["order.items", "user/login"], built
        end

        it "sends a large amount as a single packet" do
          aggregator.record(:counter, "user/login", 3_000_000_000)

          assert_equal ["user/login:3000000000|c"], write
        end

        it "rounds a fractional amount, after adding the amounts up" do
          aggregator.record(:counter, "user/login", 1.4)
          aggregator.record(:counter, "user/login", 1.4)

          assert_equal ["user/login:3|c"], write
        end

        it "adds the fraction left over by rounding to the amount of its next interval" do
          sent = Array.new(5) do
            aggregator.record(:counter, "user/login", 0.4)
            write
          end

          assert_equal [[], ["user/login:1|c"], [], ["user/login:1|c"], []], sent
        end

        it "forgets the fraction left over of a name that the next interval does not have" do
          aggregator.record(:counter, "user/login", 0.4)
          write
          aggregator.record(:counter, "user/logout", 1)
          write
          aggregator.record(:counter, "user/login", 0.4)

          assert_empty write
        end

        it "carries the fractions it carried before when sending fails" do
          aggregator.record(:counter, "user/login", 0.3)
          write
          aggregator.record(:counter, "user/login", 0.3)
          failed = aggregator.collect

          SemanticLogger::Metric::Statsd::Datagrams.stub_any_instance(:flush, -> { raise IOError, "boom" }) do
            assert_raises(IOError) { appender.write_metrics(failed) }
          end
          aggregator.record(:counter, "user/login", 0.3)

          # 0.3 + 0.3, rather than the fraction left over by the failed interval: 0.6 - 1 + 0.3.
          assert_equal ["user/login:1|c"], write
        end

        it "forgets the fractions left over in the parent process once forked" do
          aggregator.record(:counter, "user/login", 0.4)
          write
          ::Process.stub(:pid, ::Process.pid + 1) do
            SemanticLogger::CoreExt::Process.stub(:daemon?, false) do
              appender.log_metrics(snapshot(counter("user/login", 0.4)))
              appender.flush
            end
          end

          assert_empty packets
        end

        it "keeps the fractions left over in a process started by Process.daemon" do
          aggregator.record(:counter, "user/login", 0.4)
          write
          ::Process.stub(:pid, ::Process.pid + 1) do
            SemanticLogger::CoreExt::Process.stub(:daemon?, true) do
              appender.log_metrics(snapshot(counter("user/login", 0.4)))
              appender.flush
            end
          end

          assert_equal ["user/login:1|c"], packets
        end

        it "sends a sum beyond the range of a 64-bit Integer as it is" do
          appender.write_metrics(snapshot(counter("user/login", 2**70)))

          assert_equal ["user/login:#{2**70}|c"], packets
        end

        it "sends nothing for a zero amount" do
          aggregator.record(:counter, "user/login", 0)

          assert_empty write
        end

        it "sends nothing for an amount that is not finite" do
          appender.write_metrics(
            snapshot(
              counter("a", Float::INFINITY), counter("b", Float::NAN),
              counter("c", BigDecimal("Infinity")), counter("d", BigDecimal("NaN"))
            )
          )

          assert_empty packets
        end

        it "counts a finite BigDecimal amount" do
          appender.write_metrics(snapshot(counter("user/login", BigDecimal("2.5"))))

          assert_equal ["user/login:3|c"], packets
        end

        it "adds up the series that differ only by their dimensions, sending the name once" do
          aggregator.record(:counter, "user/login", 2, dimensions: {action: "login"})
          aggregator.record(:counter, "user/login", 3, dimensions: {action: "logout"})
          aggregator.record(:counter, "user/login", 1)

          assert_equal ["user/login:6|c"], write
        end
      end

      describe "a histogram" do
        it "sends a duration in milliseconds, a single timing without a sample rate" do
          aggregator.record(:histogram, "supplier.add_user", 0.25, unit: "s")

          assert_equal ["supplier.add_user:250|ms"], write
        end

        it "sends the values of any other unit as they were recorded" do
          aggregator.record(:histogram, "upload.size", 1500, unit: "By")
          aggregator.record(:histogram, "order.items", 3)

          assert_equal ["upload.size:1500|ms", "order.items:3|ms"], write
        end

        it "sends one packet per bucket, at its midpoint, with a sample rate of 1 / its count" do
          # 1.1 and 1.15 share the bucket (1.0905, 1.1892], narrowed to the minimum: (1.1, 1.1892].
          # 2.0 is alone in the bucket (1.8340, 2.0].
          [1.1, 1.15, 1.15, 2.0].each { |value| aggregator.record(:histogram, "order.items", value) }

          assert_equal ["order.items:1.1446|ms|@0.3333333333", "order.items:1.917|ms"], write
        end

        it "sends the zero bucket, and the negative ones" do
          [-4.0, 0, 0].each { |value| aggregator.record(:histogram, "balance", value) }

          # The negative bucket [-4.0, -3.66...) is narrowed to the minimum only.
          assert_equal ["balance:-3.83401|ms", "balance:0|ms|@0.5"], write
        end

        it "has a sample rate whose inverse, truncated, is the count of the bucket" do
          [2, 3, 7, 160, 3125, 6250, 100_000].each do |count|
            count.times { aggregator.record(:histogram, "order.items", 5) }
            packet = write.first

            assert_equal count, weight(packet), packet
          end
        end

        it "merges the series that differ only by their dimensions, sending each bucket once" do
          aggregator.record(:histogram, "supplier.add_user", 0.25, unit: "s", dimensions: {supplier: "a"})
          aggregator.record(:histogram, "supplier.add_user", 0.25, unit: "s", dimensions: {supplier: "b"})

          assert_equal ["supplier.add_user:250|ms|@0.5"], write
        end

        it "sends a value in fixed-point notation, without an exponent" do
          aggregator.record(:histogram, "tiny", 0.00001234)
          aggregator.record(:histogram, "huge", 1.5e20)
          sent = write

          assert_equal 2, sent.size
          sent.each { |packet| assert_match(/\A(tiny|huge):\d+(\.\d*[1-9])?\|ms\z/, packet) }
          assert_in_delta 1.5e20, Float(sent.last[/:(\d+)\|/, 1]), 1e15, sent.last
        end

        it "sends the midpoint of a bucket near the largest Float, without adding its bounds up" do
          aggregator.record(:histogram, "huge", Float::MAX)

          assert_match(/\Ahuge:\d{309}\|ms\z/, write.first)
        end

        it "leaves out a bucket whose midpoint in milliseconds is beyond the range of a Float" do
          aggregator.record(:histogram, "slowest", Float::MAX, unit: "s")
          aggregator.record(:histogram, "slow", 0.25, unit: "s")
          aggregator.record(:counter, "user/login", 1)

          assert_equal ["slow:250|ms", "user/login:1|c"], write
        end

        it "sends every bucket packet, without the client sampling them" do
          values = Array.new(2_000) { |i| (i % 400) + 1 }
          values.each { |value| aggregator.record(:histogram, "order.items", value) }
          buckets = aggregator.collect.points.first.value.each_bucket.count
          values.each { |value| aggregator.record(:histogram, "order.items", value) }
          # statsd-ruby sends a packet with a sample rate only when rand < rate.
          SemanticLogger::Metric::Statsd::Datagrams.stub_any_instance(:rand, 1.0) do
            appender.write_metrics(aggregator.collect)
          end
          sent = packets

          assert_equal buckets, sent.size
          assert_equal(values.size, sent.sum { |packet| weight(packet) })
        end

        it "sends as many packets as fit in each datagram" do
          values = Array.new(2_000) { |i| (i % 400) + 1 }
          values.each { |value| aggregator.record(:histogram, "order.items", value) }
          appender.write_metrics(aggregator.collect)
          received = datagrams

          assert_operator received.size, :>, 1
          received.each do |datagram|
            assert_operator datagram.bytesize, :<=, SemanticLogger::Metric::Statsd::Datagrams::DATAGRAM_SIZE
            assert(datagram.split("\n").all? { |line| line.match?(/\Aorder\.items:[\d.]+\|ms(\|@0\.\d+)?\z/) })
          end
          # Each datagram but the last is full: the next packet would not have fitted in it.
          received.each_cons(2) do |datagram, following|
            next_packet = following.split("\n").first

            assert_operator datagram.bytesize + 1 + next_packet.bytesize, :>,
                            SemanticLogger::Metric::Statsd::Datagrams::DATAGRAM_SIZE
          end
        end
      end

      describe "a metric name" do
        it "is sent with the kind and unit it was first given, when a merged snapshot has another" do
          histogram = SemanticLogger::Metric::ExponentialHistogram.new
          histogram.record(0.25)
          points = [
            counter("user/login", 2),
            SemanticLogger::Metric::Snapshot::Point.new(kind: :histogram, name: "user/login", value: histogram),
            SemanticLogger::Metric::Snapshot::Point.new(kind: :histogram, name: "a", value: histogram, unit: "s"),
            SemanticLogger::Metric::Snapshot::Point.new(kind: :histogram, name: "a", value: histogram, unit: "By"),
            counter("user/login", 1, dimensions: {action: "login"})
          ]
          appender.write_metrics(snapshot(*points))

          assert_equal ["user/login:3|c", "a:250|ms"], packets
        end

        it "merges histograms without changing those of the snapshot" do
          aggregator.record(:histogram, "order.items", 1, dimensions: {store: "a"})
          aggregator.record(:histogram, "order.items", 2, dimensions: {store: "b"})
          aggregator.record(:histogram, "order.items", 4, dimensions: {store: "c"})
          collected = aggregator.collect
          appender.write_metrics(collected)

          assert_equal 3, packets.size
          assert_equal([1, 1, 1], collected.points.map { |point| point.value.count })
        end
      end

      describe "a failure" do
        it "sends none of the packets, rather than those written before it" do
          aggregator.record(:counter, "user/login", 1)
          aggregator.record(:histogram, "order.items", 1)
          collected = aggregator.collect
          failing   = ->(*) { raise IOError, "boom" }

          SemanticLogger::Metric::Statsd::Datagrams.stub_any_instance(:timer, failing) do
            assert_raises(IOError) { appender.write_metrics(collected) }
          end

          assert_empty packets
        end
      end

      describe "Semantic Logger's own metrics" do
        let(:internal) do
          counter("semantic_logger.log.processed", 5, dimensions: {appender: "Io"}, internal: true)
        end

        it "are not sent by default" do
          appender.log_metrics(snapshot(internal, counter("user/login", 1)))
          appender.flush

          assert_equal ["user/login:1|c"], packets
        end

        it "are sent with internal_metrics: true" do
          subscriber = SemanticLogger::Metric::Statsd.new(url: url, internal_metrics: true)
          subscriber.log_metrics(snapshot(internal, counter("user/login", 1)))
          subscriber.flush

          assert_equal ["semantic_logger.log.processed:5|c", "user/login:1|c"], packets
        end
      end

      describe "added with add_appender" do
        after do
          SemanticLogger.appenders.dup.each do |added|
            SemanticLogger.remove_appender(added) if added.metrics_interval
          end
        end

        it "sends the metrics recorded by a logger as they are flushed" do
          SemanticLogger.add_appender(metric: :statsd, url: url)
          logger = SemanticLogger["StatsdTest"]
          logger.increment("users.signup", 2)
          logger.increment("users.signup", dimensions: {department: "clothing"})
          logger.time("supplier.add_user", duration: 125)
          SemanticLogger.flush

          assert_equal ["users.signup:3|c", "supplier.add_user:125|ms"], packets
        end
      end
    end
  end
end
