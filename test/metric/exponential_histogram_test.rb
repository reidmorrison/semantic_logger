require_relative "../test_helper"

module Metric
  class ExponentialHistogramTest < Minitest::Test
    describe SemanticLogger::Metric::ExponentialHistogram do
      let(:histogram) { SemanticLogger::Metric::ExponentialHistogram.new }

      # Bounds of the bucket holding `value` at the highest scale, before #each_bucket narrows them
      # to min and max.
      def bucket_bounds(value)
        hist = SemanticLogger::Metric::ExponentialHistogram.new
        hist.record(value)
        index = hist.positive.offset
        [hist.send(:lower_boundary, index), hist.send(:lower_boundary, index + 1)]
      end

      def recorded(*values)
        hist = SemanticLogger::Metric::ExponentialHistogram.new
        values.each { |value| hist.record(value) }
        hist
      end

      # An empty histogram lowered to `scale`.
      def at_scale(scale)
        hist = SemanticLogger::Metric::ExponentialHistogram.new
        hist.send(:downscale, hist.scale - scale)
        hist
      end

      def exact_quantile(sorted, probability)
        sorted[[(probability * sorted.size).ceil - 1, 0].max]
      end

      def lognormal(rng, median, sigma)
        normal = Math.sqrt(-2 * Math.log(1 - rng.rand)) * Math.cos(2 * Math::PI * rng.rand)
        median * Math.exp(sigma * normal)
      end

      describe "#record" do
        it "counts, sums and tracks min and max" do
          [0.5, 2, 3r, 0.25].each { |value| assert histogram.record(value) }

          assert_equal 4, histogram.count
          assert_in_delta 5.75, histogram.sum
          assert_in_delta(0.25, histogram.min)
          assert_in_delta(3.0, histogram.max)
          assert_equal 0, histogram.zero_count
          assert_equal 3, histogram.scale
        end

        it "is empty until a value is recorded" do
          assert_empty histogram
          assert_nil histogram.min
          assert_nil histogram.max
          assert_in_delta(0.0, histogram.sum)
        end

        it "ignores values that are not finite real numbers" do
          [Float::NAN, Float::INFINITY, -Float::INFINITY, 10**400, nil, "1", Complex(1, 1), :one].each do |value|
            refute histogram.record(value), value.inspect
          end

          assert_empty histogram
          assert_empty histogram.positive
          assert_in_delta(0.0, histogram.sum)
        end

        it "counts zeros, including negative zero, on their own" do
          [0, 0.0, -0.0].each { |value| histogram.record(value) }

          assert_equal 3, histogram.zero_count
          assert_equal 3, histogram.count
          assert_empty histogram.positive
          assert_empty histogram.negative
        end

        it "puts negative values in the negative buckets by magnitude" do
          histogram.record(-1.5)
          histogram.record(1.5)

          assert_equal histogram.positive.offset, histogram.negative.offset
          assert_equal [1], histogram.negative.counts
          assert_in_delta(-1.5, histogram.min)
        end
      end

      describe "bucket index" do
        it "puts a power of two at the top of the bucket below it" do
          [1.0, 2.0, 0.5, 1024.0, 2.0**-20].each do |value|
            lower, upper = bucket_bounds(value)

            assert_equal value, upper, "upper bound for #{value}"
            assert_operator lower, :<, value
          end
          assert_equal(-1, recorded(1.0).positive.offset)
          assert_equal 7, recorded(2.0).positive.offset
        end

        it "puts a value just above a power of two in the next bucket" do
          [1.0, 2.0, 0.5, 1024.0].each do |power|
            lower, upper = bucket_bounds(power.next_float)

            assert_equal power, lower
            assert_operator upper, :>, power.next_float
          end
          assert_equal 0, recorded(1.0.next_float).positive.offset
          assert_equal(-1, recorded(1.0.prev_float).positive.offset)
        end

        it "is exact at every boundary between powers of two" do
          SemanticLogger::Metric::ExponentialHistogram::BOUNDARIES.last.each_with_index do |boundary, sub|
            [-3, 0, 5].each do |exponent|
              value = Math.ldexp(boundary, exponent)
              index = (exponent * 8) + sub - 1

              assert_equal index, recorded(value).positive.offset, "on #{value}"
              assert_equal index + 1, recorded(value.next_float).positive.offset, "above #{value}"
              assert_equal index, recorded(value.prev_float).positive.offset, "below #{value}"
            end
          end
        end

        it "holds every value between its bounds at every scale" do
          rng = Random.new(7)
          (SemanticLogger::Metric::ExponentialHistogram::MIN_SCALE..3).each do |scale|
            hist   = at_scale(scale)
            values = Array.new(2_000) { Math.exp(rng.rand(-700.0..700.0)) } + [Float::MIN, Float::MAX]
            values.each do |value|
              index = hist.send(:index_of, value)
              lower = hist.send(:lower_boundary, index)
              upper = hist.send(:lower_boundary, index + 1)

              assert_operator lower, :<, value, "scale #{scale}, #{value}"
              assert_operator value, :<=, upper, "scale #{scale}, #{value}"
            end
          end
        end

        it "finds the same bucket as the exact index next to every boundary at every scale" do
          (SemanticLogger::Metric::ExponentialHistogram::MIN_SCALE..3).each do |scale|
            hist = at_scale(scale)
            (-40..40).each do |index|
              boundary = hist.send(:lower_boundary, index)
              next unless boundary >= Float::MIN && boundary < Float::MAX

              [boundary.prev_float, boundary, boundary.next_float, boundary * 1.0000001].each do |value|
                assert_equal hist.send(:exact_index_of, value), hist.send(:index_of, value), "scale #{scale}, #{value}"
              end
            end
          end
        end

        it "records an Integer like the Float it converts to" do
          assert_equal recorded(3.0).positive.offset, recorded(3).positive.offset
          assert_equal recorded(1 << 70).positive.offset, recorded(2.0**70).positive.offset
        end
      end

      describe "downscale" do
        it "lowers the scale when the range needs more than 160 buckets" do
          histogram.record(1.0.next_float)
          histogram.record(2.0**20)

          assert_equal 3, histogram.scale
          assert_equal 160, histogram.positive.counts.size

          histogram.record((2.0**20).next_float)

          assert_equal 2, histogram.scale
          assert_equal 3, histogram.positive.counts.sum
          assert_operator histogram.positive.counts.size, :<=, 160
        end

        it "keeps every value in the right bucket across many downscales" do
          values = (-40..40).map { |exponent| 1.3 * (2.0**(exponent * 7)) }
          values.each { |value| histogram.record(value) }

          assert_operator histogram.scale, :<, 0
          assert_operator histogram.positive.counts.size, :<=, 160
          assert_equal values.size, histogram.positive.counts.sum
          expected = values.group_by { |value| histogram.send(:index_of, value) }.transform_values(&:size)
          actual   = {}
          histogram.positive.each { |index, count| actual[index] = count }

          assert_equal expected, actual
        end

        it "downscales the negative range too" do
          histogram.record(-1.0)
          histogram.record(-(2.0**30))
          histogram.record(3.0)

          assert_equal 2, histogram.negative.counts.sum
          assert_operator histogram.negative.counts.size, :<=, 160
          assert_equal 2, histogram.scale
          assert_equal 1, histogram.positive.counts.sum
        end

        it "never goes below the minimum scale" do
          histogram.record(Float::MAX)
          histogram.record(5e-324)

          assert_operator histogram.scale, :>=, SemanticLogger::Metric::ExponentialHistogram::MIN_SCALE
          assert_equal 2, histogram.positive.counts.sum
        end
      end

      describe "#quantile" do
        let(:rng) { Random.new(42) }
        let(:low) { 0.0003 }
        let(:high) { 45.0 }

        def assert_quantiles(values)
          values.each { |value| histogram.record(value) }
          sorted = values.sort
          [0.5, 0.95, 0.99].each do |probability|
            exact = exact_quantile(sorted, probability)
            error = (histogram.quantile(probability) - exact).abs / exact

            assert_operator error, :<, 0.05,
                            "p#{(probability * 100).round}: #{histogram.quantile(probability)} vs #{exact}"
          end
        end

        it "estimates a uniform distribution" do
          assert_quantiles(Array.new(20_000) { rng.rand(low..high) })
        end

        it "estimates a lognormal distribution" do
          assert_quantiles(Array.new(20_000) { lognormal(rng, 0.04, 1.5).clamp(low, high) })
        end

        it "estimates a bimodal distribution" do
          values = Array.new(20_000) do
            (rng.rand < 0.7 ? lognormal(rng, 0.002, 0.5) : lognormal(rng, 5.0, 0.8)).clamp(low, high)
          end

          assert_quantiles(values)
          assert_equal 3, histogram.scale
        end

        it "stays within min and max" do
          histogram.record(1.01)
          histogram.record(1.02)

          assert_in_delta(1.01, histogram.quantile(0))
          assert_in_delta(1.02, histogram.quantile(1))
          assert histogram.quantile(0.5).between?(1.01, 1.02)
        end

        it "estimates across negative values and zeros" do
          values = [-8.0, -4.0, -2.0, 0, 0, 1.0, 2.0]
          values.each { |value| histogram.record(value) }

          assert_in_delta(-8.0, histogram.quantile(0))
          assert_in_delta(-4.0, histogram.quantile(2.0 / 7), 0.4)
          assert_in_delta(0.0, histogram.quantile(4.0 / 7))
          assert_in_delta(2.0, histogram.quantile(1))
        end

        it "returns nil when empty" do
          assert_nil histogram.quantile(0.5)
        end

        it "estimates a bucket whose lower boundary underflows to zero" do
          hist = recorded(-1.0, 5e-324, 1e300)
          hist.send(:downscale, hist.scale - SemanticLogger::Metric::ExponentialHistogram::MIN_SCALE)

          assert_predicate hist.send(:lower_boundary, hist.positive.low), :zero?
          lower, upper, count = hist.each_bucket.to_a[1]

          assert_operator lower, :>, 0.0
          assert_operator lower, :<=, 5e-324
          assert_operator upper, :>=, 5e-324
          assert_equal 1, count
          assert_in_delta(-1.0, hist.quantile(0))
          [0, 0.25, 0.5, 0.75, 1].each do |probability|
            assert_includes(-1.0..1e300, hist.quantile(probability))
          end
        end

        it "keeps subnormal bucket bounds around the subnormal values they hold" do
          [5e-324, 1e-310, 2.5e-320].each do |value|
            hist = recorded(value, 1.0)
            lower, upper, = hist.each_bucket.first

            assert_operator lower, :>, 0.0
            assert_operator lower, :<=, value
            assert_operator upper, :>=, value
            assert_equal value, hist.quantile(0)
          end
        end

        it "rejects a quantile outside 0..1" do
          [-0.1, 1.1, Float::NAN, nil, Complex(0.5, 0)].each do |probability|
            assert_raises(ArgumentError) { histogram.quantile(probability) }
          end
        end
      end

      describe "#each_bucket" do
        it "yields non-empty buckets in ascending order of value, narrowed to min and max" do
          [-3.0, -3.0, 0, 1.0, 1.5, 1.5].each { |value| histogram.record(value) }
          buckets = histogram.each_bucket.to_a

          assert_equal 4, buckets.size
          # The bucket of -3.0 is (-2**(13/8), -2**(12/8)], narrowed at the bottom to min.
          assert_equal [-3.0, -(2.0**1.5), 2], buckets[0]
          assert_equal [0.0, 0.0, 1], buckets[1]
          assert_equal [SemanticLogger::Metric::ExponentialHistogram::BOUNDARIES[3][7] / 2, 1.0, 1], buckets[2]
          assert_equal [SemanticLogger::Metric::ExponentialHistogram::BOUNDARIES[3][4], 1.5, 2], buckets[3]
        end

        it "yields the bucket bounds between the extremes" do
          [1.0, 1.05, 100.0].each { |value| histogram.record(value) }
          lower, upper, count = histogram.each_bucket.to_a[1]

          assert_equal 1, count
          assert_in_delta(1.0, lower)
          assert_in_delta(1.0905077326652577, upper)
        end

        it "yields nothing when empty" do
          assert_equal [], histogram.each_bucket.to_a
        end
      end

      describe "#explicit_bucket_counts" do
        let(:bounds) { [0, 0.005, 0.01, 0.1, 1] }

        it "counts values in (bounds[k - 1], bounds[k]]" do
          [-1.0, 0, 0.003, 0.007, 0.05, 0.5, 1.0, 2.0, 2.0].each { |value| histogram.record(value) }

          assert_equal [2, 1, 1, 1, 2, 2], histogram.explicit_bucket_counts(bounds)
        end

        it "places a lone value on a bound in the bucket it closes" do
          histogram.record(0.1)

          assert_equal [0, 0, 0, 1, 0, 0], histogram.explicit_bucket_counts(bounds)
        end

        it "is exact on bounds that are bucket boundaries" do
          [4.0, 4.0.next_float, 8.0, 8.5].each { |value| histogram.record(value) }

          assert_equal [1, 2, 1], histogram.explicit_bucket_counts([4.0, 8.0])
        end

        it "counts a bucket that a bound falls inside above that bound" do
          # 5.0 is inside the bucket (2**(18/8), 2**(19/8)], whose values cannot be told apart.
          [5.0, 6.0].each { |value| histogram.record(value) }

          assert_equal [0, 2], histogram.explicit_bucket_counts([5.0])
        end

        it "returns zeros when empty" do
          assert_equal [0] * 6, histogram.explicit_bucket_counts(bounds)
        end
      end

      describe "#sum_of_squares" do
        it "is exact when every value is the same" do
          4.times { histogram.record(3.0) }

          assert_in_delta 36.0, histogram.sum_of_squares
        end

        it "estimates the sum of squares from the bucket midpoints" do
          rng    = Random.new(3)
          values = Array.new(10_000) { lognormal(rng, 40.0, 0.9) }
          values.each { |value| histogram.record(value) }
          exact = values.sum { |value| value * value }

          assert_in_delta exact, histogram.sum_of_squares, exact * 0.01
        end

        it "counts negative values and zeros" do
          [-2.0, 0, 2.0].each { |value| histogram.record(value) }

          assert_in_delta 8.0, histogram.sum_of_squares, 8.0 * 0.1
        end

        it "is never below sum**2 / count" do
          [1.0, 1.05, 1.08].each { |value| histogram.record(value) }

          assert_operator histogram.sum_of_squares, :>=, (histogram.sum**2) / histogram.count
        end

        it "does not raise when the sum is not a number" do
          histogram.merge(recorded(Float::MAX, Float::MAX)).merge(recorded(-Float::MAX, -Float::MAX))

          assert_predicate histogram.sum, :nan?
          assert_operator histogram.sum_of_squares, :>, 0.0
        end

        it "is 0.0 when empty" do
          assert_in_delta 0.0, histogram.sum_of_squares
        end
      end

      describe "#sum" do
        it "becomes Infinity when the values add up past Float::MAX, leaving the rest right" do
          2.times { histogram.record(Float::MAX) }

          assert_equal Float::INFINITY, histogram.sum
          assert_equal 2, histogram.count
          assert_equal Float::MAX, histogram.max
        end
      end

      describe "#merge" do
        it "merges histograms at the same scale" do
          one = recorded(1.0, 2.0, -1.0)
          two = recorded(3.0, 0)
          one.merge(two)
          all = recorded(1.0, 2.0, -1.0, 3.0, 0)

          assert_equal all.count, one.count
          assert_equal all.sum, one.sum
          assert_equal all.zero_count, one.zero_count
          assert_equal all.positive.counts, one.positive.counts
          assert_equal all.positive.offset, one.positive.offset
          assert_equal all.negative.counts, one.negative.counts
          assert_in_delta(-1.0, one.min)
          assert_in_delta(3.0, one.max)
        end

        it "brings both to the lower scale" do
          narrow = recorded(1.0, 1.5, 3.0)
          wide   = recorded(0.001, 2.0**30)

          assert_equal 3, narrow.scale
          assert_operator wide.scale, :<, 3

          narrow.merge(wide)
          all = recorded(1.0, 1.5, 3.0, 0.001, 2.0**30)

          assert_equal wide.scale, narrow.scale
          assert_equal all.scale, narrow.scale
          assert_equal all.positive.offset, narrow.positive.offset
          assert_equal all.positive.counts, narrow.positive.counts
          assert_equal 5, narrow.count
        end

        it "lowers the scale further when the combined range needs it" do
          low  = recorded(2.0**-10)
          high = recorded(2.0**15)
          low.merge(high)
          all = recorded(2.0**-10, 2.0**15)

          assert_equal 2, low.scale
          assert_equal all.scale, low.scale
          assert_equal all.positive.offset, low.positive.offset
          assert_equal all.positive.counts, low.positive.counts
        end

        it "does not change the other histogram" do
          one = recorded(1.0)
          two = recorded(0.001, 2.0**30).freeze
          one.merge(two)

          assert_equal 2, two.count
          assert_equal 1, recorded(1.0).merge(recorded).count
        end

        it "keeps its scale when the other histogram holds only zeros" do
          zeros = recorded(0, 0)
          zeros.send(:scale=, SemanticLogger::Metric::ExponentialHistogram::MIN_SCALE)
          one = recorded(1.0, 3.0)
          one.merge(zeros)

          assert_equal 3, one.scale
          assert_equal 2, one.zero_count
          assert_equal recorded(1.0, 3.0).positive.counts, one.positive.counts
        end

        it "never lowers the scale below the minimum" do
          low  = recorded(5e-324)
          high = recorded(Float::MAX)
          low.merge(high)

          assert_operator low.scale, :>=, SemanticLogger::Metric::ExponentialHistogram::MIN_SCALE
          assert_equal recorded(5e-324, Float::MAX).scale, low.scale
        end

        it "merges into an empty histogram" do
          other = recorded(-5.0, 7.0)
          histogram.merge(other)

          assert_equal 2, histogram.count
          assert_in_delta(-5.0, histogram.min)
          assert_in_delta(7.0, histogram.max)
          assert_equal other.each_bucket.to_a, histogram.each_bucket.to_a
        end
      end

      describe "#freeze and #dup" do
        it "freezes the buckets" do
          histogram.record(1.0)
          histogram.record(-1.0)
          histogram.freeze

          assert_predicate histogram, :frozen?
          assert_predicate histogram.positive.counts, :frozen?
          assert_predicate histogram.negative, :frozen?
          assert_raises(FrozenError) { histogram.record(2.0) }
          assert_raises(FrozenError) { histogram.merge(recorded(2.0)) }
        end

        it "clones a frozen histogram with frozen buckets" do
          histogram.record(1.0)
          histogram.record(-1.0)
          copy = histogram.freeze.clone

          assert_predicate copy, :frozen?
          assert_predicate copy.positive, :frozen?
          assert_predicate copy.positive.counts, :frozen?
          assert_predicate copy.negative.counts, :frozen?
          assert_raises(FrozenError) { copy.positive.increment(0) }
        end

        it "clones frozen buckets with frozen counts" do
          histogram.record(1.0)
          copy = histogram.positive.freeze.clone

          assert_predicate copy, :frozen?
          assert_predicate copy.counts, :frozen?
        end

        it "clones an unfrozen histogram into an independent one" do
          histogram.record(1.0)
          copy = histogram.clone
          copy.record(1.0)

          refute_predicate copy.positive.counts, :frozen?
          assert_equal [1], histogram.positive.counts
          assert_equal [2], copy.positive.counts
        end

        it "returns an independent copy of a frozen histogram" do
          histogram.record(1.0)
          histogram.record(-1.0)
          histogram.freeze
          copy = histogram.dup

          refute_predicate copy, :frozen?
          copy.record(1.0)
          copy.record(-1.0)
          copy.record(2.0**30)

          assert_equal 2, histogram.count
          assert_equal 3, histogram.scale
          assert_equal [1], histogram.positive.counts
          assert_equal [1], histogram.negative.counts
          assert_equal 5, copy.count
          assert_operator copy.scale, :<, 3
        end
      end
    end
  end
end
