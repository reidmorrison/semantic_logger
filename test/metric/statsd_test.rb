require_relative "../test_helper"

module Metric
  class StatsdTest < Minitest::Test
    # Records the calls made to the underlying statsd-ruby client.
    class FakeStatsd
      attr_reader :timings, :increments, :decrements
      attr_accessor :namespace

      def initialize
        @timings    = []
        @increments = []
        @decrements = []
      end

      def timing(metric, duration)
        @timings << [metric, duration]
      end

      def increment(metric)
        @increments << metric
      end

      def decrement(metric)
        @decrements << metric
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
          assert_equal "udp://example.com:9125", SemanticLogger::Metric::Statsd.new(url: "udp://example.com:9125").url
        end
      end

      describe "#reopen" do
        it "raises when the scheme is not udp" do
          subscriber = SemanticLogger::Metric::Statsd.new(url: "tcp://localhost:8125")
          assert_raises(RuntimeError) { subscriber.reopen }
        end

        it "sets the namespace from the url path" do
          subscriber = SemanticLogger::Metric::Statsd.new(url: "udp://localhost:8125/my_app")
          subscriber.reopen

          assert_equal "my_app", subscriber.instance_variable_get(:@statsd).namespace
        end

        it "leaves the namespace unset when no path is supplied" do
          subscriber = SemanticLogger::Metric::Statsd.new
          subscriber.reopen

          assert_nil subscriber.instance_variable_get(:@statsd).namespace
        end
      end

      describe "#log" do
        it "sends a timing when the log has a duration" do
          appender.log(metric_log(duration: 200))

          assert_equal [[metric, 200]], fake.timings
          assert_empty fake.increments
        end

        it "increments once by default" do
          appender.log(metric_log)

          assert_equal [metric], fake.increments
        end

        it "increments by the metric amount" do
          appender.log(metric_log(metric_amount: 3))

          assert_equal [metric, metric, metric], fake.increments
        end

        it "decrements for a negative metric amount" do
          appender.log(metric_log(metric_amount: -2))

          assert_equal [metric, metric], fake.decrements
          assert_empty fake.increments
        end

        it "rounds a fractional metric amount" do
          appender.log(metric_log(metric_amount: 2.9))

          assert_equal [metric, metric, metric], fake.increments
        end
      end

      describe "#should_log?" do
        it "is true for a metric without dimensions" do
          assert appender.should_log?(metric_log)
        end

        it "is false without a metric" do
          refute appender.should_log?(metric_log(metric: nil))
        end

        it "is false when the metric has dimensions" do
          refute appender.should_log?(metric_log(dimensions: {action: "login"}))
        end
      end
    end
  end
end
