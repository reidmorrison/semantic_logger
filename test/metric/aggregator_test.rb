require_relative "../test_helper"
require_relative "../signal_trap_helper"

module Metric
  class AggregatorTest < Minitest::Test
    describe SemanticLogger::Metric::Aggregator do
      include SignalTrapHelper

      let(:start_time) { Time.at(1_000) }
      let(:end_time) { Time.at(1_060) }
      let(:aggregator) { SemanticLogger::Metric::Aggregator.new(now: start_time) }

      def points(snapshot = aggregator.collect(end_time))
        snapshot.points
      end

      def point(snapshot = aggregator.collect(end_time))
        assert_equal 1, snapshot.size, -> { snapshot.points.inspect }
        snapshot.points.first
      end

      describe "#record counter" do
        it "sums the amounts" do
          aggregator.record(:counter, "jobs.done", 1)
          aggregator.record(:counter, "jobs.done", 4)
          point = point()

          assert_equal :counter, point.kind
          assert_equal "jobs.done", point.name
          assert_nil point.unit
          assert_equal({}, point.dimensions)
          assert_equal 5, point.value
          assert_kind_of Integer, point.value
          refute_predicate point, :internal?
          refute_predicate point, :overflow?
        end

        it "becomes a Float once a Float amount is added" do
          aggregator.record(:counter, "jobs.done", 1)
          aggregator.record(:counter, "jobs.done", 0.5)
          value = point.value

          assert_kind_of Float, value
          assert_in_delta 1.5, value
        end

        it "adds other Numerics as Floats" do
          aggregator.record(:counter, "jobs.done", Rational(1, 2))
          value = point.value

          assert_kind_of Float, value
          assert_in_delta 0.5, value
        end

        it "returns true" do
          assert aggregator.record(:counter, "jobs.done", 1)
        end
      end

      describe "#record histogram" do
        it "records the values in a frozen histogram" do
          aggregator.record(:histogram, "job.perform", 0.5, unit: "s")
          aggregator.record(:histogram, "job.perform", 2, unit: "s")
          point = point()

          assert_equal :histogram, point.kind
          assert_equal "s", point.unit
          histogram = point.value

          assert_kind_of SemanticLogger::Metric::ExponentialHistogram, histogram
          assert_predicate histogram, :frozen?
          assert_equal 2, histogram.count
          assert_in_delta 2.5, histogram.sum
          assert_in_delta 0.5, histogram.min
          assert_in_delta 2.0, histogram.max
        end
      end

      describe "series identity" do
        it "keeps a name used with two kinds as two series" do
          aggregator.record(:counter, "job", 1)
          aggregator.record(:histogram, "job", 1)

          assert_equal %i[counter histogram], points.map(&:kind)
        end

        it "keeps two units of a name as two series" do
          aggregator.record(:histogram, "upload", 1, unit: "By")
          aggregator.record(:histogram, "upload", 2, unit: "KiBy")
          aggregator.record(:histogram, "upload", 3)
          aggregator.record(:histogram, "upload", 4, unit: "By")
          by_unit = points.to_h { |point| [point.unit, point.value.count] }

          assert_equal({"By" => 2, "KiBy" => 1, nil => 1}, by_unit)
        end

        it "keeps internal and application metrics with the same name apart" do
          aggregator.record(:counter, "processed", 1, internal: true)
          aggregator.record(:counter, "processed", 2)
          aggregator.record(:counter, "processed", 3, internal: true)
          by_internal = points.to_h { |point| [point.internal?, point.value] }

          assert_equal({true => 4, false => 2}, by_internal)
        end
      end

      describe "dimensions" do
        it "treats nil and empty dimensions as the same series" do
          aggregator.record(:counter, "jobs", 1)
          aggregator.record(:counter, "jobs", 1, dimensions: {})

          assert_equal 2, point.value
        end

        it "ignores the order of the dimensions" do
          aggregator.record(:counter, "jobs", 1, dimensions: {a: 1, b: 2})
          aggregator.record(:counter, "jobs", 1, dimensions: {b: 2, a: 1})
          point = point()

          assert_equal 2, point.value
          assert_equal({a: 1, b: 2}, point.dimensions)
        end

        it "keeps a series per set of dimensions" do
          aggregator.record(:counter, "jobs", 1, dimensions: {queue: "a"})
          aggregator.record(:counter, "jobs", 2, dimensions: {queue: "b"})
          aggregator.record(:counter, "jobs", 3, dimensions: {queue: "a"})
          by_queue = points.to_h { |point| [point.dimensions, point.value] }

          assert_equal({{queue: "a"} => 4, {queue: "b"} => 2}, by_queue)
        end

        it "keeps a frozen copy, not the caller's Hash" do
          value      = +"a"
          dimensions = {queue: value}
          aggregator.record(:counter, "jobs", 1, dimensions: dimensions)
          dimensions[:queue] = "b"
          value << "x"
          kept = point.dimensions

          assert_equal({queue: "a"}, kept)
          assert_predicate kept, :frozen?
          assert_predicate kept[:queue], :frozen?
        end

        it "gives a point without dimensions a frozen empty Hash" do
          aggregator.record(:counter, "jobs", 1)
          dimensions = point.dimensions

          assert_empty dimensions
          assert_predicate dimensions, :frozen?
        end
      end

      describe "cardinality" do
        let(:aggregator) { SemanticLogger::Metric::Aggregator.new(series_limit: 3, now: start_time) }

        it "sends further dimension sets to one overflow series" do
          aggregator.record(:counter, "jobs", 1)
          aggregator.record(:counter, "jobs", 1, dimensions: {id: 1})
          aggregator.record(:counter, "jobs", 1, dimensions: {id: 2})
          aggregator.record(:counter, "jobs", 1, dimensions: {id: 3})
          aggregator.record(:counter, "jobs", 1, dimensions: {id: 4})
          aggregator.record(:counter, "jobs", 1, dimensions: {id: 1})
          aggregator.record(:counter, "jobs", 1)
          points = points()

          assert_equal [{}, {id: 1}, {id: 2}, {"otel.metric.overflow" => true}], points.map(&:dimensions)
          assert_equal [2, 2, 1, 2], points.map(&:value)
          assert_equal [false, false, false, true], points.map(&:overflow?)
        end

        it "limits each metric on its own" do
          4.times { |i| aggregator.record(:counter, "a", 1, dimensions: {id: i}) }
          4.times { |i| aggregator.record(:histogram, "a", i, dimensions: {id: i}) }
          4.times { |i| aggregator.record(:counter, "b", 1, dimensions: {id: i}) }

          assert_equal 12, points.size
        end

        it "adds dimensions given as the overflow dimensions to the overflow series" do
          aggregator.record(:counter, "jobs", 1, dimensions: {"otel.metric.overflow" => true})
          4.times { |i| aggregator.record(:counter, "jobs", 1, dimensions: {id: i}) }
          points = points()

          assert_equal 4, points.size
          assert_equal 2, points.last.value
          assert_predicate points.last, :overflow?
        end

        it "starts counting again in the next interval" do
          4.times { |i| aggregator.record(:counter, "jobs", 1, dimensions: {id: i}) }
          aggregator.collect(end_time)
          aggregator.record(:counter, "jobs", 1, dimensions: {id: 3})

          refute_predicate point, :overflow?
        end

        it "defaults to 2000" do
          assert_equal 2000, SemanticLogger::Metric::Aggregator.new.series_limit
        end
      end

      describe "input it ignores" do
        it "ignores values that are not finite real Numerics" do
          [Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(1, 1), nil, "1", :one].each do |value|
            refute aggregator.record(:counter, "jobs", value), value.inspect
            refute aggregator.record(:histogram, "jobs", value), value.inspect
          end

          assert_empty aggregator.collect(end_time)
        end

        it "ignores an unknown kind" do
          refute aggregator.record(:gauge, "jobs", 1)
          assert_empty aggregator.collect(end_time)
        end

        it "ignores dimensions that are not a Hash" do
          refute aggregator.record(:counter, "jobs", 1, dimensions: [[:a, 1]])
          assert_empty aggregator.collect(end_time)
        end

        it "records negative amounts, which the caller filters" do
          aggregator.record(:counter, "jobs", -1)

          assert_equal(-1, point.value)
        end
      end

      describe "#collect" do
        it "returns a frozen snapshot of the interval" do
          aggregator.record(:counter, "jobs", 1)
          snapshot = aggregator.collect(end_time)

          assert_predicate snapshot, :frozen?
          assert_predicate snapshot.points, :frozen?
          assert_predicate snapshot.points.first, :frozen?
          assert_equal start_time, snapshot.start_time
          assert_equal end_time, snapshot.end_time
        end

        it "returns an empty snapshot when nothing was recorded" do
          snapshot = aggregator.collect(end_time)

          assert_predicate snapshot, :empty?
          assert_equal start_time, snapshot.start_time
          assert_equal end_time, snapshot.end_time
        end

        it "starts the next interval" do
          aggregator.record(:counter, "jobs", 1)
          aggregator.collect(end_time)
          aggregator.record(:counter, "jobs", 2)
          later    = Time.at(1_120)
          snapshot = aggregator.collect(later)

          assert_equal end_time, snapshot.start_time
          assert_equal later, snapshot.end_time
          assert_equal 2, point(snapshot).value
        end

        it "hands over histograms that later records do not change" do
          aggregator.record(:histogram, "job", 1)
          histogram = point.value
          aggregator.record(:histogram, "job", 2)

          assert_equal 1, histogram.count
        end
      end

      describe "#reset" do
        it "discards what was recorded and restarts the interval" do
          aggregator.record(:counter, "jobs", 1)
          aggregator.reset(end_time)
          later    = Time.at(1_120)
          snapshot = aggregator.collect(later)

          assert_predicate snapshot, :empty?
          assert_equal end_time, snapshot.start_time
        end
      end

      describe "in a signal trap" do
        it "queues the record and adds it on the next collect" do
          dimensions = {queue: +"a"}
          recorded   = in_signal_trap { aggregator.record(:counter, "jobs", 2, dimensions: dimensions) }
          dimensions[:queue] << "x"

          assert recorded
          point = point()

          assert_equal 2, point.value
          assert_equal({queue: "a"}, point.dimensions)
        end

        it "queues the record and adds it on the next record" do
          in_signal_trap { aggregator.record(:histogram, "job", 3, unit: "s") }
          aggregator.record(:histogram, "job", 5, unit: "s")
          point = point()

          assert_equal 2, point.value.count
          assert_in_delta 8.0, point.value.sum
        end

        it "ignores bad input without queuing it" do
          refute(in_signal_trap { aggregator.record(:counter, "jobs", Float::NAN) })
          assert_empty aggregator.collect(end_time)
        end

        it "discards queued records on reset" do
          in_signal_trap { aggregator.record(:counter, "jobs", 1) }
          aggregator.reset(end_time)

          assert_empty aggregator.collect(Time.at(1_120))
        end
      end

      describe "with several threads" do
        it "loses no record" do
          threads = Array.new(4) do |i|
            Thread.new do
              1_000.times do |j|
                aggregator.record(:counter, "jobs", 1, dimensions: {thread: i})
                aggregator.record(:histogram, "job", j)
              end
            end
          end
          collected = []
          collected << aggregator.collect while threads.any?(&:alive?)
          threads.each(&:join)
          collected << aggregator.collect
          snapshot = collected.reduce { |earlier, later| earlier.merge(later) }
          counters = snapshot.select(&:counter?)

          assert_equal [1_000] * 4, counters.map(&:value)
          assert_equal 4_000, snapshot.find(&:histogram?).value.count
        end
      end
    end
  end
end
