require_relative "../test_helper"
require "bigdecimal"

module Metric
  class StatsdTest < Minitest::Test
    # Records the calls made to the underlying statsd-ruby client.
    class FakeStatsd
      attr_reader :timings, :counts
      attr_accessor :namespace

      def initialize
        @timings = []
        @counts  = []
      end

      def timing(metric, duration)
        @timings << [metric, duration]
      end

      def count(metric, amount)
        @counts << [metric, amount]
      end
    end

    describe SemanticLogger::Metric::Statsd do
      let(:metric) { "user/login" }
      let(:fake) { FakeStatsd.new }

      let(:appender) do
        appender = SemanticLogger::Metric::Statsd.new
        appender.instance_variable_set(:@statsd, fake)
        appender
      end

      def metric_log(metric: "user/login", duration: nil, metric_amount: nil, dimensions: nil, level: :info)
        log               = SemanticLogger::Log.new("StatsdTest", level)
        log.metric        = metric
        log.duration      = duration
        log.metric_amount = metric_amount
        log.dimensions    = dimensions
        log
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

        it "connects, so that it records metrics without a reopen" do
          counts = []
          ::Statsd.stub_any_instance(:count, ->(metric, amount) { counts << [metric, amount] }) do
            subscriber = SemanticLogger::Metric::Statsd.new
            subscriber.info(metric: "user/login")
          end

          assert_equal [["user/login", 1]], counts
        end

        it "sets the namespace from the url path" do
          subscriber = SemanticLogger::Metric::Statsd.new(url: "udp://127.0.0.1:8125/my_app")

          assert_equal "my_app", subscriber.instance_variable_get(:@statsd).namespace
        end

        it "leaves the namespace unset when no path is supplied" do
          subscriber = SemanticLogger::Metric::Statsd.new

          assert_nil subscriber.instance_variable_get(:@statsd).namespace
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

      describe "#log" do
        it "sends a timing when the log has a duration" do
          appender.log(metric_log(duration: 200))

          assert_equal [[metric, 200]], fake.timings
          assert_empty fake.counts
        end

        it "counts once by default" do
          appender.log(metric_log)

          assert_equal [[metric, 1]], fake.counts
        end

        it "counts the metric amount in a single packet" do
          appender.log(metric_log(metric_amount: 3))

          assert_equal [[metric, 3]], fake.counts
        end

        it "sends a large metric amount as a single packet" do
          appender.log(metric_log(metric_amount: 3_000_000_000))

          assert_equal [[metric, 3_000_000_000]], fake.counts
        end

        it "counts a negative metric amount" do
          appender.log(metric_log(metric_amount: -2))

          assert_equal [[metric, -2]], fake.counts
        end

        it "rounds a fractional metric amount" do
          appender.log(metric_log(metric_amount: 2.9))

          assert_equal [[metric, 3]], fake.counts
        end

        it "sends nothing for a zero metric amount" do
          appender.log(metric_log(metric_amount: 0))

          assert_empty fake.counts
        end

        it "ignores a metric amount that is not finite" do
          appender.log(metric_log(metric_amount: Float::INFINITY))
          appender.log(metric_log(metric_amount: Float::NAN))

          assert_empty fake.counts
        end

        it "ignores a BigDecimal metric amount that is not finite" do
          appender.log(metric_log(metric_amount: BigDecimal("Infinity")))
          appender.log(metric_log(metric_amount: BigDecimal("-Infinity")))
          appender.log(metric_log(metric_amount: BigDecimal("NaN")))

          assert_empty fake.counts
        end

        it "counts a finite BigDecimal metric amount" do
          appender.log(metric_log(metric_amount: BigDecimal("2.5")))

          assert_equal [[metric, 3]], fake.counts
        end
      end

      describe "#should_log?" do
        it "is true for a metric without dimensions" do
          assert appender.should_log?(metric_log)
        end

        it "is false without a metric" do
          refute appender.should_log?(metric_log(metric: nil))
        end

        it "is true when the metric has dimensions" do
          assert appender.should_log?(metric_log(dimensions: {action: "login"}))
        end
      end

      describe "a metric with dimensions" do
        it "is counted under its name alone" do
          appender.info(metric: metric, metric_amount: 2, dimensions: {action: "login"})

          assert_equal [[metric, 2]], fake.counts
        end

        it "is timed under its name alone" do
          appender.info(metric: metric, duration: 200, dimensions: {action: "login"})

          assert_equal [[metric, 200]], fake.timings
        end

        it "can be left out with a filter" do
          appender.filter = ->(log) { !log.dimensions? }
          appender.info(metric: metric, dimensions: {action: "login"})
          appender.info(metric: metric)

          assert_equal [[metric, 1]], fake.counts
        end
      end

      describe "options" do
        it "applies the filter: and level: given to add_appender" do
          filter     = ->(log) { !log.dimensions? }
          subscriber = SemanticLogger::Appender.factory(metric: :statsd, filter: filter, level: :warn)

          refute subscriber.should_log?(metric_log(level: :info))
          refute subscriber.should_log?(metric_log(level: :warn, dimensions: {action: "login"}))
          assert subscriber.should_log?(metric_log(level: :warn))
        end
      end
    end
  end
end
