require_relative "../test_helper"

module Metric
  class SnapshotTest < Minitest::Test
    describe SemanticLogger::Metric::Snapshot do
      def new_point(**) = SemanticLogger::Metric::Snapshot::Point.new(**)

      def histogram(*values)
        hist = SemanticLogger::Metric::ExponentialHistogram.new
        values.each { |value| hist.record(value) }
        hist
      end

      def snapshot(start, finish, *points)
        SemanticLogger::Metric::Snapshot.new(start_time: Time.at(start), end_time: Time.at(finish), points: points)
      end

      describe SemanticLogger::Metric::Snapshot::Point do
        it "defaults the unit, dimensions and internal" do
          point = new_point(kind: :counter, name: "jobs", value: 1)

          assert_nil point.unit
          assert_equal({}, point.dimensions)
          refute point.internal
          assert_predicate point, :counter?
          refute_predicate point, :histogram?
        end

        it "is frozen, with a frozen copy of its dimensions and a frozen value" do
          dimensions = {queue: "a"}
          value      = histogram(1)
          point      = new_point(kind: :histogram, name: "job", value: value, dimensions: dimensions)

          assert_predicate point, :frozen?
          assert_predicate point.dimensions, :frozen?
          refute_predicate dimensions, :frozen?
          assert_predicate value, :frozen?
        end

        it "knows an overflow series" do
          point = new_point(kind: :counter, name: "jobs", value: 1, dimensions: {"otel.metric.overflow" => true})

          assert_predicate point, :overflow?
        end

        it "has an identity from scope, kind, name, unit, internal and dimensions" do
          point = new_point(kind: :histogram, name: "job", unit: "s", value: histogram, dimensions: {a: 1},
                            scope: "Jobs")

          assert_equal ["Jobs", :histogram, "job", "s", false, {a: 1}], point.identity
        end

        it "has no scope when internal" do
          assert_nil new_point(kind: :counter, name: "processed", value: 1, internal: true, scope: "Jobs").scope
        end

        it "keeps its scope when merged and redacted" do
          point    = new_point(kind: :counter, name: "jobs", value: 1, dimensions: {"password" => "x"}, scope: "Jobs")
          redactor = SemanticLogger::Redactor.new(["password"])

          assert_equal "Jobs", point.merge(point).scope
          assert_equal "Jobs", point.redact(redactor).scope
        end
      end

      describe "#initialize" do
        it "is frozen, with frozen points" do
          points   = [new_point(kind: :counter, name: "jobs", value: 1)]
          snapshot = snapshot(0, 60, *points)
          points << new_point(kind: :counter, name: "more", value: 1)

          assert_predicate snapshot, :frozen?
          assert_predicate snapshot.points, :frozen?
          assert_equal 1, snapshot.size
        end
      end

      describe "Enumerable" do
        it "iterates the points" do
          points   = [new_point(kind: :counter, name: "a", value: 1), new_point(kind: :counter, name: "b", value: 2)]
          snapshot = snapshot(0, 60, *points)

          assert_equal %w[a b], snapshot.map(&:name)
          assert_equal 2, snapshot.each.size
          refute_empty snapshot
          assert_empty snapshot(0, 60)
        end
      end

      describe "#merge" do
        it "spans both intervals" do
          merged = snapshot(0, 60).merge(snapshot(60, 120))

          assert_equal Time.at(0), merged.start_time
          assert_equal Time.at(120), merged.end_time
          assert_predicate merged, :empty?
          assert_predicate merged, :frozen?
        end

        it "adds counter sums and keeps the points of one snapshot" do
          earlier = snapshot(
            0, 60,
            new_point(kind: :counter, name: "a", value: 1),
            new_point(kind: :counter, name: "b", value: 2, dimensions: {x: 1})
          )
          later = snapshot(
            60, 120,
            new_point(kind: :counter, name: "b", value: 0.5, dimensions: {x: 1}),
            new_point(kind: :counter, name: "b", value: 7, dimensions: {x: 2}),
            new_point(kind: :counter, name: "a", value: 3, internal: true)
          )
          merged = earlier.merge(later)

          assert_equal([["a", {}, false, 1], ["b", {x: 1}, false, 2.5], ["b", {x: 2}, false, 7], ["a", {}, true, 3]],
                       merged.map { |point| [point.name, point.dimensions, point.internal, point.value] })
        end

        it "merges histograms into a frozen copy" do
          first  = histogram(1, 2)
          second = histogram(1000)
          merged = snapshot(0, 60, new_point(kind: :histogram, name: "job", unit: "s", value: first)).
                   merge(snapshot(60, 120, new_point(kind: :histogram, name: "job", unit: "s", value: second)))
          value  = merged.points.first.value

          assert_equal 1, merged.size
          assert_equal 3, value.count
          assert_in_delta 1003.0, value.sum
          assert_predicate value, :frozen?
          assert_equal 2, first.count
          assert_equal 1, second.count
        end

        it "keeps series that differ in kind or unit apart" do
          merged = snapshot(
            0, 60,
            new_point(kind: :counter, name: "a", value: 1),
            new_point(kind: :histogram, name: "a", unit: "s", value: histogram(1))
          ).merge(
            snapshot(
              60, 120,
              new_point(kind: :histogram, name: "a", unit: "ms", value: histogram(1)),
              new_point(kind: :histogram, name: "a", unit: "s", value: histogram(2))
            )
          )

          assert_equal([[:counter, nil], [:histogram, "s"], [:histogram, "ms"]], merged.map { |p| [p.kind, p.unit] })
          assert_equal 2, merged.points[1].value.count
        end

        it "merges the points of one series within the earlier snapshot too" do
          earlier = snapshot(
            0, 60,
            new_point(kind: :counter, name: "a", value: 1),
            new_point(kind: :counter, name: "a", value: 2)
          )
          merged = earlier.merge(snapshot(60, 120, new_point(kind: :counter, name: "a", value: 4)))

          assert_equal [7], merged.map(&:value)
        end

        it "adds the records dropped, keeping the earliest first name dropped" do
          earlier = SemanticLogger::Metric::Snapshot.new(
            start_time: Time.at(0), end_time: Time.at(60),
            dropped_by_name_limit: 2, first_name_dropped: "x", dropped_by_conflict: {"a" => 1},
            dropped_by_internal_conflict: {"p" => 1}
          )
          later = SemanticLogger::Metric::Snapshot.new(
            start_time: Time.at(60), end_time: Time.at(120),
            dropped_by_name_limit: 3, first_name_dropped: "y", dropped_by_conflict: {"a" => 2, "b" => 1},
            dropped_by_internal_conflict: {"p" => 2}
          )
          merged = earlier.merge(later)

          assert_equal 5, merged.dropped_by_name_limit
          assert_equal "x", merged.first_name_dropped
          assert_equal({"a" => 3, "b" => 1}, merged.dropped_by_conflict)
          assert_predicate merged.dropped_by_conflict, :frozen?
          assert_equal({"p" => 3}, merged.dropped_by_internal_conflict)
          assert_predicate merged.dropped_by_internal_conflict, :frozen?
          assert_equal "y", snapshot(0, 60).merge(later).first_name_dropped
        end
      end

      describe "records dropped" do
        it "has none by default" do
          snapshot = snapshot(0, 60)

          assert_equal 0, snapshot.dropped_by_name_limit
          assert_nil snapshot.first_name_dropped
          assert_equal({}, snapshot.dropped_by_conflict)
          assert_equal({}, snapshot.dropped_by_internal_conflict)
          refute_predicate snapshot, :dropped?
        end

        it "keeps a frozen copy of the records of internal metrics dropped by conflict" do
          counts   = {"processed" => 1}
          snapshot = SemanticLogger::Metric::Snapshot.new(start_time: Time.at(0), end_time: Time.at(60),
                                                          dropped_by_internal_conflict: counts)
          counts["b"] = 1

          assert_equal({"processed" => 1}, snapshot.dropped_by_internal_conflict)
          assert_predicate snapshot.dropped_by_internal_conflict, :frozen?
          assert_predicate snapshot, :dropped?
        end

        it "keeps a frozen copy of the records dropped by conflict" do
          counts   = {"a" => 1}
          snapshot = SemanticLogger::Metric::Snapshot.new(start_time: Time.at(0), end_time: Time.at(60),
                                                          dropped_by_conflict: counts)
          counts["b"] = 1

          assert_equal({"a" => 1}, snapshot.dropped_by_conflict)
          assert_predicate snapshot.dropped_by_conflict, :frozen?
          assert_predicate snapshot, :dropped?
          assert_predicate snapshot, :empty?
        end
      end

      describe "#merged_by" do
        it "adds counters and merges histograms of the same key, whatever their dimensions" do
          first  = histogram(1, 2)
          merged = snapshot(
            0, 60,
            new_point(kind: :counter, name: "a", value: 1, dimensions: {x: 1}),
            new_point(kind: :counter, name: "a", value: 2.5, dimensions: {x: 2}),
            new_point(kind: :histogram, name: "b", unit: "s", value: first, dimensions: {x: 1}),
            new_point(kind: :histogram, name: "b", unit: "s", value: histogram(1000))
          ).merged_by(&:name)

          assert_equal %w[a b], merged.keys
          assert_equal [:counter, nil, 3.5], merged["a"]
          assert_equal [:histogram, "s"], merged["b"].first(2)
          assert_equal 3, merged["b"][2].count
          assert_equal 2, first.count
          assert_predicate first, :frozen?
        end

        it "keeps the kind and unit of the first point of a key, leaving out the others" do
          merged = snapshot(
            0, 60,
            new_point(kind: :histogram, name: "a", unit: "s", value: histogram(1)),
            new_point(kind: :counter, name: "a", value: 1),
            new_point(kind: :histogram, name: "a", unit: "ms", value: histogram(1)),
            new_point(kind: :histogram, name: "a", unit: "s", value: histogram(2))
          ).merged_by(&:name)

          assert_equal [:histogram, "s"], merged["a"].first(2)
          assert_equal 2, merged["a"][2].count
        end

        it "gives the point's own value for a key of one point" do
          value  = histogram(1)
          merged = snapshot(0, 60, new_point(kind: :histogram, name: "a", value: value)).merged_by(&:name)

          assert_same value, merged["a"][2]
        end
      end

      describe "#without_scopes" do
        it "merges the series that differ only by their scope, and keeps the others apart" do
          snapshot = snapshot(
            0, 60,
            new_point(kind: :counter, name: "jobs", value: 1, scope: "Orders"),
            new_point(kind: :counter, name: "jobs", value: 2, scope: "Payments"),
            new_point(kind: :counter, name: "jobs", value: 4, dimensions: {"queue" => "a"}, scope: "Orders"),
            new_point(kind: :histogram, name: "jobs", value: histogram(1.0), scope: "Payments"),
            new_point(kind: :histogram, name: "jobs", value: histogram(2.0), scope: "Orders")
          )
          unscoped = snapshot.without_scopes

          assert_equal [nil], unscoped.map(&:scope).uniq
          assert_equal(
            [[:counter, {}, 3], [:counter, {"queue" => "a"}, 4], [:histogram, {}, 2]],
            unscoped.map { |point| [point.kind, point.dimensions, point.counter? ? point.value : point.value.count] }
          )
          assert_equal snapshot.start_time, unscoped.start_time
          assert_equal snapshot.end_time, unscoped.end_time
          assert_equal(2, snapshot.select(&:histogram?).sum { |point| point.value.count })
        end

        it "is itself when no point has a scope" do
          snapshot = snapshot(0, 60, new_point(kind: :counter, name: "jobs", value: 1))

          assert_same snapshot, snapshot.without_scopes
        end
      end

      describe "#without_internal" do
        it "drops the internal points" do
          snapshot = snapshot(
            0, 60,
            new_point(kind: :counter, name: "a", value: 1),
            new_point(kind: :counter, name: "processed", value: 1, internal: true)
          )
          external = snapshot.without_internal

          assert_equal %w[a], external.map(&:name)
          assert_equal snapshot.start_time, external.start_time
          assert_equal snapshot.end_time, external.end_time
        end

        it "keeps the records dropped" do
          snapshot = SemanticLogger::Metric::Snapshot.new(
            start_time: Time.at(0), end_time: Time.at(60),
            points:     [new_point(kind: :counter, name: "processed", value: 1, internal: true)],
            dropped_by_name_limit: 1, first_name_dropped: "x", dropped_by_conflict: {"a" => 1},
            dropped_by_internal_conflict: {"processed" => 1}
          )
          external = snapshot.without_internal

          assert_empty external
          assert_equal 1, external.dropped_by_name_limit
          assert_equal "x", external.first_name_dropped
          assert_equal({"a" => 1}, external.dropped_by_conflict)
          assert_equal({"processed" => 1}, external.dropped_by_internal_conflict)
        end

        it "returns itself without internal points" do
          snapshot = snapshot(0, 60, new_point(kind: :counter, name: "a", value: 1))

          assert_same snapshot, snapshot.without_internal
        end
      end
    end
  end
end
