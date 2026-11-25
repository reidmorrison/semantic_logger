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

        it "drops an amount that would make a Float sum non-finite, keeping the sum" do
          aggregator.record(:counter, "bytes", Float::MAX)

          refute aggregator.record(:counter, "bytes", Float::MAX)
          assert_equal Float::MAX, point.value
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
        it "keeps the first kind of a name and drops records of another, counting them" do
          aggregator.record(:counter, "job", 1)

          refute aggregator.record(:histogram, "job", 1)
          refute aggregator.record(:histogram, "job", 2)
          snapshot = aggregator.collect(end_time)

          assert_equal [:counter], snapshot.map(&:kind)
          assert_equal({"job" => 2}, snapshot.dropped_by_conflict)
          assert_predicate snapshot.dropped_by_conflict, :frozen?
          assert_predicate snapshot, :dropped?
        end

        it "keeps the first unit of a name and drops records of another, counting them" do
          aggregator.record(:histogram, "upload", 1, unit: "By")
          aggregator.record(:histogram, "upload", 2, unit: "KiBy")
          aggregator.record(:histogram, "upload", 3)
          aggregator.record(:histogram, "upload", 4, unit: "By")
          snapshot = aggregator.collect(end_time)
          point    = point(snapshot)

          assert_equal "By", point.unit
          assert_equal 2, point.value.count
          assert_equal({"upload" => 2}, snapshot.dropped_by_conflict)
        end

        it "lets the next interval start with another kind or unit" do
          aggregator.record(:counter, "job", 1)
          aggregator.collect(end_time)
          aggregator.record(:histogram, "job", 1, unit: "s")
          snapshot = aggregator.collect(Time.at(1_120))

          assert_equal([[:histogram, "s"]], snapshot.map { |point| [point.kind, point.unit] })
          refute_predicate snapshot, :dropped?
        end

        it "treats internal: nil as false" do
          aggregator.record(:counter, "processed", 1, internal: nil)
          aggregator.record(:counter, "processed", 2, internal: false)
          aggregator.record(:counter, "processed", 3)
          point = point()

          assert_equal 6, point.value
          refute_predicate point, :internal?
        end

        it "makes Symbol and String names one metric with a frozen String name" do
          aggregator.record(:counter, :jobs, 1)
          aggregator.record(:counter, +"jobs", 2)
          point = point()

          assert_equal 3, point.value
          assert_equal "jobs", point.name
          assert_predicate point.name, :frozen?
        end

        it "counts conflicts of internal metrics apart from those of application metrics" do
          aggregator.record(:counter, "processed", 1)
          aggregator.record(:counter, "processed", 1, internal: true)
          aggregator.record(:histogram, "processed", 1)
          aggregator.record(:histogram, "processed", 1, internal: true)
          aggregator.record(:histogram, "processed", 1, internal: true)
          snapshot = aggregator.collect(end_time)

          assert_equal({"processed" => 1}, snapshot.dropped_by_conflict)
          assert_equal({"processed" => 2}, snapshot.dropped_by_internal_conflict)
          assert_predicate snapshot.dropped_by_internal_conflict, :frozen?
        end

        it "keeps internal and application metrics with the same name apart" do
          aggregator.record(:counter, "processed", 1, internal: true)
          aggregator.record(:counter, "processed", 2)
          aggregator.record(:counter, "processed", 3, internal: true)
          by_internal = points.to_h { |point| [point.internal?, point.value] }

          assert_equal({true => 4, false => 2}, by_internal)
        end
      end

      describe "scope" do
        it "keeps the metrics of each scope apart" do
          aggregator.record(:counter, "jobs", 1, scope: "Orders")
          aggregator.record(:counter, "jobs", 2, scope: "Payments")
          aggregator.record(:counter, "jobs", 4, scope: "Orders")
          snapshot = aggregator.collect(end_time)

          assert_equal([["Orders", 5], ["Payments", 2]], snapshot.map { |point| [point.scope, point.value] })
        end

        it "gives a name the kind and unit of its first record in every scope, dropping and counting others" do
          aggregator.record(:counter, "jobs", 1, scope: "Orders")

          refute aggregator.record(:histogram, "jobs", 1.5, scope: "Reports")
          refute aggregator.record(:counter, "jobs", 1, unit: "{job}", scope: "Payments")
          assert aggregator.record(:counter, "jobs", 1, scope: "Payments")
          snapshot = aggregator.collect(end_time)

          assert_equal(%w[Orders Payments], snapshot.map(&:scope))
          assert_equal([:counter], snapshot.map(&:kind).uniq)
          assert_equal({"jobs" => 2}, snapshot.dropped_by_conflict)
        end

        it "gives a point no scope when it was recorded without one" do
          aggregator.record(:counter, "jobs", 1)

          assert_nil point.scope
        end

        it "makes a Symbol and a String scope one, a frozen String, with a frozen copy of the caller's" do
          scope = +"Orders"
          aggregator.record(:counter, "jobs", 1, scope: scope)
          scope << "X"
          aggregator.record(:counter, "jobs", 2, scope: :Orders)
          point = point()

          assert_equal "Orders", point.scope
          assert_predicate point.scope, :frozen?
          assert_equal 3, point.value
        end

        it "gives an internal metric no scope" do
          aggregator.record(:counter, "semantic_logger.log.processed", 1, internal: true, scope: "Orders")
          aggregator.record(:counter, "semantic_logger.log.processed", 2, internal: true, scope: "Payments")
          point = point()

          assert_nil point.scope
          assert_equal 3, point.value
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
          assert_equal({"a" => 1, "b" => 2}, point.dimensions)
        end

        it "keeps a series per set of dimensions" do
          aggregator.record(:counter, "jobs", 1, dimensions: {queue: "a"})
          aggregator.record(:counter, "jobs", 2, dimensions: {queue: "b"})
          aggregator.record(:counter, "jobs", 3, dimensions: {queue: "a"})
          by_queue = points.to_h { |point| [point.dimensions, point.value] }

          assert_equal({{"queue" => "a"} => 4, {"queue" => "b"} => 2}, by_queue)
        end

        it "makes Symbol and String keys and Symbol values one series with String keys" do
          aggregator.record(:counter, "jobs", 1, dimensions: {region: "eu"})
          aggregator.record(:counter, "jobs", 1, dimensions: {"region" => "eu"})
          aggregator.record(:counter, "jobs", 1, dimensions: {region: :eu})
          aggregator.record(:counter, "jobs", 1, dimensions: {"region" => :eu})
          point = point()

          assert_equal 4, point.value
          assert_equal({"region" => "eu"}, point.dimensions)
        end

        it "keeps other scalar values as they are" do
          dimensions = {code: 200, ratio: 0.5, ok: true, failed: false, none: nil}
          aggregator.record(:counter, "jobs", 1, dimensions: dimensions)
          aggregator.record(:counter, "jobs", 1, dimensions: {code: "200"})

          assert_equal [{"code" => 200, "ratio" => 0.5, "ok" => true, "failed" => false, "none" => nil},
                        {"code" => "200"}],
                       points.map(&:dimensions)
        end

        it "keeps a frozen copy, not the caller's Hash" do
          value      = +"a"
          dimensions = {queue: value}
          aggregator.record(:counter, "jobs", 1, dimensions: dimensions)
          dimensions[:queue] = "b"
          value << "x"
          aggregator.record(:counter, "jobs", 1, dimensions: {queue: "a"})
          point = point()
          kept  = point.dimensions

          assert_equal 2, point.value
          assert_equal({"queue" => "a"}, kept)
          assert_predicate kept, :frozen?
          assert_predicate kept.keys.first, :frozen?
          assert_predicate kept["queue"], :frozen?
        end

        it "keeps a frozen copy of an Array of scalars" do
          list = [+"a", :b, 1]
          aggregator.record(:counter, "jobs", 1, dimensions: {list: list})
          list.first << "x"
          list << 2
          aggregator.record(:counter, "jobs", 1, dimensions: {list: ["a", "b", 1]})
          point = point()
          kept  = point.dimensions["list"]

          assert_equal 2, point.value
          assert_equal ["a", "b", 1], kept
          assert_predicate kept, :frozen?
          assert_predicate kept.first, :frozen?
        end

        it "converts other values to frozen Strings" do
          nested = {a: [1]}
          aggregator.record(:counter, "jobs", 1, dimensions: {nested: nested, list: [[1]], nan: Float::NAN, 1 => :x})
          nested[:a] << 2
          aggregator.record(:counter, "jobs", 1, dimensions: {nested: {a: [1]}, list: [[1]], nan: Float::NAN, 1 => :x})
          point = point()
          kept  = point.dimensions

          assert_equal 2, point.value
          assert_equal({"nested" => {a: [1]}.to_s, "list" => "[[1]]", "nan" => "NaN", "1" => "x"}, kept)
          assert(kept.values.all?(&:frozen?))
        end

        it "never raises converting a value to text" do
          deep = []
          10_000.times { deep = [deep] }
          to_s_raises = Object.new
          def to_s_raises.to_s = raise(ArgumentError, "broken")
          to_s_nil = Object.new
          def to_s_nil.to_s = nil
          dimensions = {deep: deep, raises: to_s_raises, nil: to_s_nil, basic: BasicObject.new, {a: 1} => 1}

          assert aggregator.record(:counter, "jobs", 1, dimensions: dimensions)
          kept = point.dimensions

          assert_equal "Object", kept["raises"]
          assert_equal "Object", kept["nil"]
          assert_equal "BasicObject", kept["basic"]
          assert_equal({a: 1}.inspect, kept.keys.last)
          assert_kind_of String, kept["deep"]
          assert(kept.all? { |key, value| key.frozen? && value.frozen? })
        end

        it "finds the series again when the caller changes the Hash it passed in" do
          dimensions = {queue: "a"}
          aggregator.record(:counter, "jobs", 1, dimensions: dimensions)
          dimensions[:queue] = "b"
          aggregator.record(:counter, "jobs", 1, dimensions: dimensions)
          aggregator.record(:counter, "jobs", 1, dimensions: {queue: "a"})
          by_queue = points.to_h { |point| [point.dimensions, point.value] }

          assert_equal({{"queue" => "a"} => 2, {"queue" => "b"} => 1}, by_queue)
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

          assert_equal [{}, {"id" => 1}, {"id" => 2}, {"otel.metric.overflow" => true}], points.map(&:dimensions)
          assert_equal [2, 2, 1, 2], points.map(&:value)
          assert_equal [false, false, false, true], points.map(&:overflow?)
        end

        it "counts the series without dimensions when it comes after the limit is reached" do
          3.times { |i| aggregator.record(:counter, "jobs", 1, dimensions: {id: i}) }
          aggregator.record(:counter, "jobs", 1)
          aggregator.record(:counter, "jobs", 1, dimensions: {})
          points = points()

          assert_equal [{"id" => 0}, {"id" => 1}, {"id" => 2}, {"otel.metric.overflow" => true}],
                       points.map(&:dimensions)
          assert_equal 2, points.last.value
        end

        it "limits each metric on its own" do
          4.times { |i| aggregator.record(:counter, "a", 1, dimensions: {id: i}) }
          4.times { |i| aggregator.record(:histogram, "b", i, dimensions: {id: i}) }
          4.times { |i| aggregator.record(:counter, "c", 1, dimensions: {id: i}) }

          assert_equal 12, points.size
        end

        it "counts dimensions given in two ways as one series" do
          aggregator.record(:counter, "jobs", 1, dimensions: {id: "1"})
          aggregator.record(:counter, "jobs", 1, dimensions: {"id" => :"1"})
          aggregator.record(:counter, "jobs", 1, dimensions: {id: "2"})
          aggregator.record(:counter, "jobs", 1, dimensions: {id: "3"})

          refute(points.any?(&:overflow?))
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

      describe "name limit" do
        let(:aggregator) { SemanticLogger::Metric::Aggregator.new(name_limit: 2, now: start_time) }

        it "drops records of names beyond the limit, counting them and naming the first" do
          aggregator.record(:counter, "a", 1)
          aggregator.record(:histogram, "b", 1)

          refute aggregator.record(:counter, "c", 1)
          refute aggregator.record(:counter, "d", 1)
          refute aggregator.record(:counter, "c", 1)
          assert aggregator.record(:counter, "a", 1)
          snapshot = aggregator.collect(end_time)

          assert_equal %w[a b], snapshot.map(&:name)
          assert_equal 3, snapshot.dropped_by_name_limit
          assert_equal "c", snapshot.first_name_dropped
          assert_predicate snapshot.first_name_dropped, :frozen?
          assert_predicate snapshot, :dropped?
        end

        it "counts a name in each scope as a metric of its own" do
          aggregator.record(:counter, "jobs", 1, scope: "Orders")
          aggregator.record(:counter, "jobs", 1, scope: "Payments")

          refute aggregator.record(:counter, "jobs", 1, scope: "Reports")
          snapshot = aggregator.collect(end_time)

          assert_equal %w[Orders Payments], snapshot.map(&:scope)
          assert_equal 1, snapshot.dropped_by_name_limit
          assert_equal "jobs", snapshot.first_name_dropped
          assert_equal "Reports", snapshot.first_scope_dropped
        end

        it "does not count internal metrics" do
          aggregator.record(:counter, "a", 1)
          aggregator.record(:counter, "b", 1)
          aggregator.record(:counter, "semantic_logger.log.processed", 1, internal: true)
          snapshot = aggregator.collect(end_time)

          assert_equal 3, snapshot.size
          refute_predicate snapshot, :dropped?
        end

        it "starts counting again in the next interval" do
          3.times { |i| aggregator.record(:counter, "name#{i}", 1) }
          aggregator.collect(end_time)
          aggregator.record(:counter, "name2", 1)
          snapshot = aggregator.collect(Time.at(1_120))

          assert_equal %w[name2], snapshot.map(&:name)
          assert_equal 0, snapshot.dropped_by_name_limit
          assert_nil snapshot.first_name_dropped
        end

        it "defaults to 2000" do
          assert_equal 2000, SemanticLogger::Metric::Aggregator.new.name_limit
        end
      end

      describe "input it ignores" do
        it "ignores values that are not finite real Numerics" do
          [Float::NAN, Float::INFINITY, -Float::INFINITY, Rational(10**400), Complex(1, 1), nil, "1"].each do |value|
            refute aggregator.record(:counter, "jobs", value), value.inspect
            refute aggregator.record(:histogram, "latency", value), value.inspect
          end

          assert_empty aggregator.collect(end_time)
        end

        it "ignores an Integer too large for a Float in a histogram only" do
          refute aggregator.record(:histogram, "latency", 10**400)
          assert aggregator.record(:counter, "jobs", 10**400)
          assert aggregator.record(:counter, "jobs", 1)

          assert_equal (10**400) + 1, point.value
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

      describe "an error while recording" do
        it "is not taken for a signal trap, and leaves the Mutex unlocked" do
          broken = -> { raise(ThreadError, "not from a lock") }

          SemanticLogger::Metric::Aggregator::Sum.stub(:new, broken) do
            assert_raises(ThreadError) { aggregator.record(:counter, "jobs", 1) }
          end

          assert aggregator.record(:counter, "jobs", 1)
          assert_equal 1, point.value
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
          assert_equal({"queue" => "a"}, point.dimensions)
        end

        it "queues the record with a frozen copy of its scope" do
          scope = +"Orders"
          in_signal_trap { aggregator.record(:counter, "jobs", 2, scope: scope) }
          scope << "X"

          assert_equal "Orders", point.scope
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
