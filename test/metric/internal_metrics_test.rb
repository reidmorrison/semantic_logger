require_relative "../test_helper"

module Metric
  class InternalMetricsTest < Minitest::Test
    # Stands in for a processor: answers the statistics it is given, and whether a metric appender
    # writes Semantic Logger's own metrics. Counts how often its statistics are read.
    class FakeProcessor
      attr_accessor :stats_value, :internal_metrics
      attr_reader :reads

      def initialize(processed: 0, dropped: 0, appenders: [], internal_metrics: true)
        @stats_value      = {processed: processed, dropped: dropped, appenders: appenders}
        @internal_metrics = internal_metrics
        @reads            = 0
      end

      def internal_metrics? = @internal_metrics

      def stats
        @reads += 1
        @stats_value
      end

      def set(processed: nil, dropped: nil, appenders: nil)
        @stats_value = @stats_value.merge({processed: processed, dropped: dropped, appenders: appenders}.compact)
      end
    end

    describe SemanticLogger::Metric::InternalMetrics do
      let(:internal) { SemanticLogger::Metric::InternalMetrics.new }
      let(:aggregator) { SemanticLogger::Metric::Aggregator.new }
      let(:processor) { FakeProcessor.new(processed: 10) }

      def async_stats(name, processed: 0, dropped: 0, failed: 0)
        {name: name, async: true, processed: processed, dropped: dropped, failed: failed}
      end

      # Returns [Hash] the amounts recorded since the last call, by dimensions.
      def recorded
        aggregator.collect.points.to_h do |point|
          assert_equal "semantic_logger.log.processed", point.name
          assert_equal "{log_record}", point.unit
          assert_equal :counter, point.kind
          assert_predicate point, :internal?
          [point.dimensions, point.value]
        end
      end

      # Records what was counted since the previous collection, then returns it.
      def collection
        internal.record(aggregator, processor)
        recorded
      end

      it "records what was counted since the baseline, then since each collection" do
        internal.baseline(processor)
        processor.set(processed: 15)

        assert_equal({{"appender" => "main"} => 5}, collection)

        processor.set(processed: 18, dropped: 2)

        assert_equal({{"appender" => "main"} => 3, {"appender" => "main", "error.type" => "dropped"} => 2}, collection)
        assert_empty collection
      end

      it "records nothing at the first collection without a baseline, only from then on" do
        assert_empty collection

        processor.set(processed: 11)

        assert_equal({{"appender" => "main"} => 1}, collection)
      end

      it "counts each appender with a queue of its own, with error.type for dropped and failed entries" do
        processor.set(appenders: [async_stats("File", processed: 1)])
        internal.baseline(processor)
        processor.set(appenders: [async_stats("File", processed: 4, dropped: 2, failed: 1)])

        expected = {
          {"appender" => "File"}                            => 3,
          {"appender" => "File", "error.type" => "dropped"} => 2,
          {"appender" => "File", "error.type" => "failed"}  => 1
        }

        assert_equal expected, collection
      end

      it "skips the appenders without a queue of their own" do
        internal.baseline(processor)
        processor.set(processed: 12, appenders: [{name: "IO", async: false}])

        assert_equal({{"appender" => "main"} => 2}, collection)
      end

      it "tells apart the appenders with a name already used by their position" do
        internal.baseline(processor)
        processor.set(
          appenders: [async_stats("File", processed: 1), async_stats("main", processed: 2),
                      async_stats("File", processed: 3)]
        )

        expected = {{"appender" => "File"} => 1, {"appender" => "main#2"} => 2, {"appender" => "File#2"} => 3}

        assert_equal expected, collection
      end

      it "counts an appender added since the previous collection from zero, and forgets one removed" do
        internal.baseline(processor)
        processor.set(appenders: [async_stats("Added", processed: 4)])

        assert_equal({{"appender" => "Added"} => 4}, collection)

        processor.set(appenders: [])

        assert_empty collection
      end

      it "records the new total, never a negative amount, when a total went backwards" do
        processor.set(appenders: [async_stats("File", processed: 20)])
        internal.baseline(processor)
        processor.set(processed: 3, appenders: [async_stats("File", processed: 5)])

        assert_equal({{"appender" => "main"} => 3, {"appender" => "File"} => 5}, collection)
      end

      it "counts the main queue of a new processor from zero, such as after sync!" do
        processor.set(appenders: [async_stats("File", processed: 1)])
        internal.baseline(processor)
        replacement = FakeProcessor.new(processed: 12, appenders: [async_stats("File", processed: 2)])
        internal.record(aggregator, replacement)

        assert_equal({{"appender" => "main"} => 12, {"appender" => "File"} => 1}, recorded)
      end

      it "reads nothing, and forgets the totals it read, while no metric appender writes them" do
        internal.baseline(processor)
        processor.internal_metrics = false
        reads = processor.reads

        refute internal.baseline(processor)
        assert_empty collection
        assert_equal reads, processor.reads

        processor.internal_metrics = true
        processor.set(processed: 30)

        assert_empty collection, "should read a new baseline rather than count from the forgotten one"
      end

      it "asks a processor that cannot answer for nothing" do
        internal.record(aggregator, Object.new)

        assert_empty recorded
      end

      describe "#for_child" do
        it "counts from the totals now in a forked child" do
          internal.baseline(processor)
          processor.set(processed: 14)
          child = internal.for_child(keep: false, processor: processor)
          processor.set(processed: 15)
          child.record(aggregator, processor)

          assert_equal({{"appender" => "main"} => 1}, recorded)
        end

        it "keeps the totals of the previous collection in a process started by Process.daemon" do
          internal.baseline(processor)
          processor.set(processed: 14)
          child = internal.for_child(keep: true, processor: processor)
          processor.set(processed: 15)
          child.record(aggregator, processor)

          assert_equal({{"appender" => "main"} => 5}, recorded)
        end
      end
    end

    describe "with metric appenders" do
      let(:writing) { InMemoryMetricAppender.new(internal_metrics: true) }
      let(:other) { InMemoryMetricAppender.new }
      # Takes only the entries of this test's logger, rather than any that another test left on the queue.
      let(:queued) do
        InMemoryAppender.new(filter: /\AInternalMetricsTest\z/).tap do |appender|
          appender.name = "InternalMetricsQueued"
        end
      end
      let(:logger) { SemanticLogger["InternalMetricsTest"] }

      after do
        SemanticLogger.appenders.dup.each do |added|
          SemanticLogger.remove_appender(added) if added.metrics_interval || added.name == queued.name
        end
      end

      # Returns [Hash] the sum of the internal amounts written by the appender, by dimensions.
      def written(appender)
        appender.points.select(&:internal?).each_with_object(Hash.new(0)) do |point, sums|
          sums[point.dimensions] += point.value
        end
      end

      it "writes the counts only to the metric appenders added with internal_metrics: true" do
        SemanticLogger.add_appender(metric: other)
        SemanticLogger.add_appender(metric: writing)
        SemanticLogger.add_appender(appender: queued, async: true)

        assert_predicate SemanticLogger::Logger.processor, :internal_metrics?

        3.times { |i| logger.info("Entry #{i}") }
        # The first flush delivers the metrics, then the entries are processed: the second delivers
        # their counts.
        SemanticLogger.flush
        SemanticLogger.flush
        counts = written(writing)

        assert_equal 3, counts[{"appender" => queued.name}]
        assert_operator counts[{"appender" => "main"}], :>=, 3
        assert_empty other.points.select(&:internal?)
      end

      it "reads no statistics while no metric appender writes them" do
        SemanticLogger.add_appender(metric: other)
        processor = SemanticLogger::Logger.processor
        reads     = 0
        stats     = processor.method(:stats)

        refute_predicate processor, :internal_metrics?

        processor.stub(:stats, -> { (reads += 1) && stats.call }) do
          logger.info("Entry")
          SemanticLogger.flush
          SemanticLogger.flush
        end

        assert_equal 0, reads
        assert_empty other.points.select(&:internal?)
      end
    end
  end
end
