require_relative "../test_helper"

module Metric
  # SemanticLogger.sensitive_keys= redacts the dimensions of the metrics given to the metric appenders,
  # once per interval as each snapshot is collected.
  class RedactionTest < Minitest::Test
    Snapshot = SemanticLogger::Metric::Snapshot
    Point    = SemanticLogger::Metric::Snapshot::Point

    def self.histogram(*values)
      histogram = SemanticLogger::Metric::ExponentialHistogram.new
      values.each { |value| histogram.record(value) }
      histogram
    end

    describe "Snapshot#redact" do
      let(:redactor) { SemanticLogger::Redactor.new([:password, /\Aapi[._]key\z/]) }

      def snapshot(*points)
        Snapshot.new(start_time: Time.at(0), end_time: Time.at(60), points: points)
      end

      def counter(amount, dimensions, name: "users.signup")
        Point.new(kind: :counter, name: name, value: amount, dimensions: dimensions)
      end

      def histogram(dimensions, *values)
        Point.new(kind: :histogram, name: "supplier.call", unit: "s", value: RedactionTest.histogram(*values),
                  dimensions: dimensions)
      end

      it "replaces the value of a sensitive dimension of a counter and a histogram" do
        redacted = snapshot(
          counter(2, {"password" => "secret", "plan" => "free"}),
          histogram({"api_key" => "abc"}, 0.5)
        ).redact(redactor)

        assert_equal [{"password" => "[FILTERED]", "plan" => "free"}, {"api_key" => "[FILTERED]"}],
                     redacted.points.map(&:dimensions)
        assert_equal [2, 1], [redacted.points[0].value, redacted.points[1].value.count]
        assert_predicate redacted, :frozen?
        assert(redacted.points.all? { |point| point.dimensions.frozen? })
      end

      it "merges the series that become the same, adding sums and merging histograms" do
        redacted = snapshot(
          counter(2, {"password" => "a", "plan" => "free"}),
          counter(3, {"password" => "b", "plan" => "free"}),
          counter(7, {"password" => "c", "plan" => "paid"}),
          histogram({"password" => "a"}, 1, 2),
          histogram({"password" => "b"}, 4)
        ).redact(redactor)

        assert_equal 3, redacted.size
        counters = redacted.select(&:counter?).to_h { |point| [point.dimensions["plan"], point.value] }

        assert_equal({"free" => 5, "paid" => 7}, counters)
        merged = redacted.find(&:histogram?)

        assert_equal({"password" => "[FILTERED]"}, merged.dimensions)
        assert_equal 3, merged.value.count
        assert_in_delta 7.0, merged.value.sum
      end

      it "keeps the interval and the counts of records dropped" do
        original = Snapshot.new(start_time: Time.at(0), end_time: Time.at(60), dropped_by_name_limit: 2,
                                first_name_dropped: "x", points: [counter(1, {"password" => "a"})])
        redacted = original.redact(redactor)

        assert_equal [Time.at(0), Time.at(60), 2, "x"],
                     [redacted.start_time, redacted.end_time, redacted.dropped_by_name_limit,
                      redacted.first_name_dropped]
      end

      it "returns itself, and its points, when no dimension is sensitive" do
        point    = counter(1, {"plan" => "free", "region" => "eu"})
        original = snapshot(point, counter(1, {}))

        assert_same original, original.redact(redactor)
        assert_same point, point.redact(redactor)
      end

      it "leaves the overflow series alone" do
        original = snapshot(counter(1, Point::OVERFLOW_DIMENSIONS))

        assert_same original, original.redact(redactor)
        assert_predicate original.points.first, :overflow?
      end

      it "keeps String keys when the redactor fails" do
        failing  = SemanticLogger::Redactor.new(->(_name) { raise ArgumentError, "boom" })
        redacted = SemanticLogger::Logger.processor.logger.stub(:warn, nil) do
          snapshot(counter(1, {"password" => "a"})).redact(failing)
        end

        assert_equal({"redaction_failed" => "ArgumentError"}, redacted.points.first.dimensions)
      end

      it "sees the redacted dimensions in merged_by and merge" do
        first  = snapshot(counter(2, {"password" => "a"})).redact(redactor)
        second = snapshot(counter(3, {"password" => "b"})).redact(redactor)

        assert_equal({{"password" => "[FILTERED]"} => [:counter, nil, 5]},
                     first.merge(second).merged_by(&:dimensions))
        assert_equal 1, first.merge(second).size
      end
    end

    describe "metrics delivered to a metric appender" do
      let(:logger) do
        logger       = SemanticLogger["Metric::RedactionTest"]
        logger.level = :info
        logger
      end
      let(:metric_appender) { InMemoryMetricAppender.new }

      before do
        SemanticLogger.sensitive_keys = %i[password token]
        SemanticLogger.add_appender(metric: metric_appender)
      end

      after do
        SemanticLogger.sensitive_keys = nil
        SemanticLogger.appenders.dup.each do |added|
          SemanticLogger.remove_appender(added) if added.metrics_interval
        end
      end

      # Returns [Array<SemanticLogger::Metric::Snapshot::Point>] the points written once flushed, but
      # those of the test reporter and Semantic Logger's own.
      def points(appender = metric_appender)
        SemanticLogger.flush
        appender.points.reject { |point| point.name.start_with?("minitest/") || point.internal? }
      end

      it "redacts and merges the series of increment" do
        logger.increment("users.signup", 2, dimensions: {password: "a", plan: "free"})
        logger.increment("users.signup", 3, dimensions: {password: "b", plan: "free"})
        logger.increment("users.signup", dimensions: {plan: "free"})

        result = points.to_h { |point| [point.dimensions, point.value] }

        assert_equal({{"password" => "[FILTERED]", "plan" => "free"} => 5, {"plan" => "free"} => 1}, result)
      end

      it "redacts and merges the series of time and record" do
        logger.time("supplier.call", duration: 1000, dimensions: {access_token: "a"})
        logger.time("supplier.call", duration: 3000, dimensions: {access_token: "b"})
        logger.record("order.items", 4, dimensions: {"userPassword" => "c", "plan" => "free"})

        timed, recorded = points.partition { |point| point.name == "supplier.call" }

        assert_equal 1, timed.size
        assert_equal({"access_token" => "[FILTERED]"}, timed.first.dimensions)
        assert_equal 2, timed.first.value.count
        assert_in_delta 4.0, timed.first.value.sum
        assert_equal [{"userPassword" => "[FILTERED]", "plan" => "free"}], recorded.map(&:dimensions)
      end

      it "redacts the metric: of a log call, at any level" do
        logger.info("Signed up", metric: "users.signup", dimensions: {password: "a"})
        logger.debug("Signed up", metric: "users.signup", dimensions: {password: "b"})

        assert_equal([[{"password" => "[FILTERED]"}, 2]], points.map { |point| [point.dimensions, point.value] })
      end

      it "leaves Semantic Logger's own metrics as they are, while redacting the application's" do
        internal = SemanticLogger.add_appender(metric: InMemoryMetricAppender.new(internal_metrics: true))
        logger.info("Counted", metric: "users.signup", dimensions: {password: "a"})
        # The entry is counted once the processor has written it, which the first flush waits for.
        SemanticLogger.flush
        logger.info("Counted")
        SemanticLogger.flush
        own = internal.points.select(&:internal?)

        refute_empty own
        assert_includes own.map(&:dimensions), {"appender" => "main"}
        assert_equal [{"password" => "[FILTERED]"}], points(internal).map(&:dimensions).uniq
      end

      it "redacts again when the sensitive keys change" do
        logger.increment("users.signup", dimensions: {password: "a"})

        assert_equal [{"password" => "[FILTERED]"}], points.map(&:dimensions)

        SemanticLogger.sensitive_keys = nil
        logger.increment("users.signup", dimensions: {password: "a"})

        assert_equal [{"password" => "a"}], points.last(1).map(&:dimensions)
      end

      it "delivers the snapshot itself without sensitive keys" do
        SemanticLogger.sensitive_keys = nil
        snapshot = Snapshot.new(start_time: Time.at(0), end_time: Time.at(60),
                                points: [Point.new(kind: :counter, name: "a", value: 1,
                                                   dimensions: {"password" => "a"})])

        assert_same snapshot, SemanticLogger::Metric.collector.send(:redact, snapshot)
      end

      it "delivers nothing, and reports it, when redacting the snapshot fails" do
        snapshot = Object.new
        def snapshot.redact(_redactor) = raise(ArgumentError, "boom")
        errors   = []
        result   = SemanticLogger::Logger.processor.logger.stub(:error, ->(message, _e = nil) { errors << message }) do
          SemanticLogger::Metric.collector.send(:redact, snapshot)
        end

        assert_nil result
        assert_equal ["Failed to collect metrics"], errors
      end
    end
  end
end
