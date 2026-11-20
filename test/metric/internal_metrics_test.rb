require_relative "../test_helper"

module Metric
  class InternalMetricsTest < Minitest::Test
    # Stands in for an appender with a queue of its own: answers its name and counts.
    class FakeQueue
      attr_accessor :name

      def initialize(name, processed: 0, dropped: 0, failed: 0)
        @name   = name
        @counts = {processed: processed, dropped: dropped, failed: failed}
      end

      def set(**counts)
        @counts = @counts.merge(counts)
      end

      def queue_log_counts = @counts
    end

    # Stands in for a processor: answers the counts of its main queue and of the queues it is given, and
    # whether a metric appender writes Semantic Logger's own metrics. Counts how often they are read.
    class FakeProcessor
      attr_accessor :queues, :internal_metrics
      attr_reader :reads

      def initialize(processed: 0, dropped: 0, queues: [], internal_metrics: true)
        @counts           = {processed: processed, dropped: dropped}
        @queues           = queues
        @internal_metrics = internal_metrics
        @reads            = 0
      end

      def internal_metrics? = @internal_metrics

      def queue_log_counts = @counts

      def each_queue_log_counts
        @reads += 1
        yield self, nil, @counts
        @queues.each { |queue| yield queue, queue.name, queue.queue_log_counts }
      end

      def set(**counts)
        @counts = @counts.merge(counts)
      end
    end

    describe SemanticLogger::Metric::InternalMetrics do
      let(:internal) { SemanticLogger::Metric::InternalMetrics.new }
      let(:aggregator) { SemanticLogger::Metric::Aggregator.new }
      let(:processor) { FakeProcessor.new(processed: 10) }

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
        file = FakeQueue.new("File", processed: 1)
        processor.queues = [file]
        internal.baseline(processor)
        file.set(processed: 4, dropped: 2, failed: 1)

        expected = {
          {"appender" => "File"}                            => 3,
          {"appender" => "File", "error.type" => "dropped"} => 2,
          {"appender" => "File", "error.type" => "failed"}  => 1
        }

        assert_equal expected, collection
      end

      it "tells apart the appenders with a name already used by their position" do
        internal.baseline(processor)
        processor.queues = [FakeQueue.new("File", processed: 1), FakeQueue.new("main", processed: 2),
                            FakeQueue.new("File", processed: 3)]

        expected = {{"appender" => "File"} => 1, {"appender" => "main#2"} => 2, {"appender" => "File#2"} => 3}

        assert_equal expected, collection
      end

      it "counts an appender added since the previous collection from zero" do
        internal.baseline(processor)
        processor.queues = [FakeQueue.new("Added", processed: 4)]

        assert_equal({{"appender" => "Added"} => 4}, collection)
      end

      it "records no negative amount when a count went backwards" do
        file             = FakeQueue.new("File", processed: 20)
        processor.queues = [file]
        internal.baseline(processor)
        file.set(processed: 5)

        assert_empty collection
      end

      it "counts the main queue of a new processor from zero, such as after sync!" do
        file             = FakeQueue.new("File", processed: 1)
        processor.queues = [file]
        internal.baseline(processor)
        file.set(processed: 2)
        replacement = FakeProcessor.new(processed: 12, queues: [file])
        internal.record(aggregator, replacement)

        assert_equal({{"appender" => "main"} => 12, {"appender" => "File"} => 1}, recorded)
      end

      it "reads nothing, and forgets the counts it read, while no metric appender writes them" do
        internal.baseline(processor)
        processor.internal_metrics = false
        reads                      = processor.reads

        refute internal.baseline(processor)
        assert_empty collection
        assert_equal reads, processor.reads

        processor.internal_metrics = true
        processor.set(processed: 30)

        assert_empty collection, "should read a new baseline rather than count from the forgotten one"
      end

      describe "a queue gone since the previous collection" do
        it "records what it counted since then, under its name then, and then forgets it" do
          file             = FakeQueue.new("File", processed: 1)
          processor.queues = [FakeQueue.new("File"), file]
          internal.baseline(processor)
          processor.queues = processor.queues.first(1)
          file.set(processed: 4, failed: 1)

          expected = {{"appender" => "File#2"} => 3, {"appender" => "File#2", "error.type" => "failed"} => 1}

          assert_equal expected, collection

          file.set(processed: 9)

          assert_empty collection
        end

        it "adds to the queue that took over its name, rather than compare one with the other" do
          first            = FakeQueue.new("IO", processed: 100)
          second           = FakeQueue.new("IO", processed: 5)
          processor.queues = [first, second]
          internal.baseline(processor)
          first.set(processed: 103)
          second.set(processed: 7)
          processor.queues = [second]

          assert_equal({{"appender" => "IO"} => 5}, collection)
        end

        it "records what the main queue of a processor replaced, such as by sync!, counted until then" do
          internal.baseline(processor)
          processor.set(processed: 13)
          replacement = FakeProcessor.new(processed: 2)
          internal.record(aggregator, replacement)

          assert_equal({{"appender" => "main"} => 5}, recorded)
        end

        it "records nothing for a queue that answers no counts" do
          file             = FakeQueue.new("File", processed: 1)
          processor.queues = [file]
          internal.baseline(processor)
          processor.queues = []

          file.stub(:queue_log_counts, nil) { assert_empty collection }
        end
      end

      describe "#baseline" do
        it "keeps the counts it read while collecting goes on" do
          internal.baseline(processor)
          processor.set(processed: 12)
          internal.baseline(processor)

          assert_equal({{"appender" => "main"} => 2}, collection)
        end

        it "forgets the counts read before, once collecting starts again" do
          internal.baseline(processor)
          processor.set(processed: 40)
          internal.baseline(processor, restart: true)
          processor.set(processed: 41)

          assert_equal({{"appender" => "main"} => 1}, collection)
        end

        it "forgets them even where its lock cannot be locked, so that the next collection starts afresh" do
          internal.baseline(processor)
          processor.set(processed: 40)

          internal.instance_variable_get(:@lock).synchronize do
            refute internal.baseline(processor, restart: true)
          end

          assert_empty collection
        end
      end

      describe "#check" do
        it "forgets the counts once no metric appender writes them" do
          internal.baseline(processor)
          processor.internal_metrics = false
          internal.check(processor)
          processor.internal_metrics = true
          processor.set(processed: 50)
          internal.baseline(processor)
          processor.set(processed: 51)

          assert_equal({{"appender" => "main"} => 1}, collection)
        end

        it "keeps the counts while a metric appender writes them" do
          internal.baseline(processor)
          internal.check(processor)
          processor.set(processed: 13)

          assert_equal({{"appender" => "main"} => 3}, collection)
        end
      end

      describe "#for_child" do
        it "counts from the counts now in a forked child" do
          internal.baseline(processor)
          processor.set(processed: 14)
          child = internal.for_child(keep: false, processor: processor)
          processor.set(processed: 15)
          child.record(aggregator, processor)

          assert_equal({{"appender" => "main"} => 1}, recorded)
        end

        it "keeps the counts of the previous collection in a process started by Process.daemon" do
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

      it "reads no counts while no metric appender writes them" do
        SemanticLogger.add_appender(metric: other)
        processor = SemanticLogger::Logger.processor
        reads     = 0
        counts    = processor.method(:each_queue_log_counts)

        refute_predicate processor, :internal_metrics?

        processor.stub(:each_queue_log_counts, ->(&block) { (reads += 1) && counts.call(&block) }) do
          logger.info("Entry")
          SemanticLogger.flush
          SemanticLogger.flush
        end

        assert_equal 0, reads
        assert_empty other.points.select(&:internal?)
      end

      it "records what an appender counted since the previous collection as it is removed" do
        SemanticLogger.add_appender(metric: writing)
        SemanticLogger.add_appender(appender: queued, async: true)
        SemanticLogger.flush
        SemanticLogger.flush
        writing.snapshots.clear

        3.times { |i| logger.info("Entry #{i}") }
        # Collects before the entries are written to the appender, then writes them, so that the next
        # collection would be the first to count them, were they not counted as it is removed.
        SemanticLogger.flush
        SemanticLogger.remove_appender(queued)
        SemanticLogger.flush

        assert_equal 3, written(writing)[{"appender" => queued.name}]
      end

      it "records what an appender counted once it is gone, however it went, at the next collection" do
        SemanticLogger.add_appender(metric: writing)
        added = SemanticLogger.add_appender(appender: queued, async: true)
        SemanticLogger.flush
        SemanticLogger.flush
        writing.snapshots.clear

        3.times { |i| logger.info("Entry #{i}") }
        SemanticLogger.flush
        # Taken out of the appenders without SemanticLogger.remove_appender, so nothing is told it went.
        SemanticLogger.appenders.delete(added)
        added.flush
        SemanticLogger.flush

        assert_equal 3, written(writing)[{"appender" => queued.name}]
      ensure
        added&.close
      end

      it "compares each queue with its own counts once an appender removed leaves its name to another" do
        first = SemanticLogger.add_appender(appender: queued, async: true)
        other_logger = SemanticLogger["InternalMetricsOther"]
        second = InMemoryAppender.new(filter: /\AInternalMetricsOther\z/).tap { |appender| appender.name = queued.name }
        SemanticLogger.add_appender(appender: second, async: true)
        SemanticLogger.add_appender(metric: writing)
        10.times { |i| other_logger.info("Other #{i}") }
        SemanticLogger.flush
        SemanticLogger.flush
        writing.snapshots.clear

        SemanticLogger.remove_appender(first)
        2.times { |i| other_logger.info("More #{i}") }
        SemanticLogger.flush
        SemanticLogger.flush
        counts = written(writing)

        assert_equal 2, counts[{"appender" => queued.name}]
        refute counts.key?({"appender" => "#{queued.name}#2"})
      end

      it "counts from when a metric appender is added again, after the last one was removed" do
        SemanticLogger.add_appender(metric: writing)
        SemanticLogger.add_appender(appender: queued, async: true)
        SemanticLogger.flush
        SemanticLogger.remove_appender(writing)

        refute_predicate SemanticLogger::Logger.processor, :collecting_metrics?

        50.times { |i| logger.info("Unwritten #{i}") }
        SemanticLogger.flush
        again = SemanticLogger.add_appender(metric: InMemoryMetricAppender.new(internal_metrics: true))
        logger.info("Written")
        SemanticLogger.flush
        SemanticLogger.flush

        assert_equal 1, written(again)[{"appender" => queued.name}]
      end
    end
  end
end
