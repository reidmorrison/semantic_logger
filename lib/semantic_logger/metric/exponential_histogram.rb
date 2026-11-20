module SemanticLogger
  module Metric
    # A histogram with the OpenTelemetry base-2 exponential bucket layout.
    #
    # At scale `s` the bucket with index `i` holds the values in (base**i, base**(i + 1)], where
    # base = 2**(2**-s). Positive and negative values have a range of buckets each (a negative value
    # goes in the bucket of its magnitude), zeros are counted on their own.
    #
    # It starts at MAX_SCALE. When a value would need more than MAX_SIZE buckets in either range,
    # the scale is lowered, merging neighbouring buckets, until it fits. Since every boundary at a
    # lower scale is also a boundary at a higher scale, no count ever lands in the wrong bucket.
    #
    # Not thread-safe: its owner serializes access. `dup` returns an independent, unfrozen copy;
    # `freeze` also freezes the buckets, and so does `clone` of a frozen histogram.
    class ExponentialHistogram
      # Highest (finest) scale, where each power of two is split into 2**3 = 8 buckets.
      MAX_SCALE = 3
      # Lowest scale in the OpenTelemetry specification; at it every Float fits in a few buckets.
      MIN_SCALE = -10
      # Maximum number of buckets in each of the positive and negative ranges.
      MAX_SIZE = 160

      # For each scale 0..MAX_SCALE, the bucket boundaries within one power of two: 2**(j / 2**scale)
      # for j in 0...2**scale. A boundary at a lower scale is computed from the same exponent as
      # the one at a higher scale, so both are the same Float.
      BOUNDARIES = (0..MAX_SCALE).map do |scale|
        size = 1 << scale
        Array.new(size) { |j| 2.0**(j.to_f / size) }.freeze
      end.freeze

      # How close, in buckets, a value's computed position may come to a bucket boundary before
      # #index_of finds its bucket exactly instead. Math.log2 is off by a few units in the last
      # place at most, so a position further than this from a boundary is in the right bucket.
      EDGE = 1e-6

      # A contiguous range of bucket counts: `counts[k]` is the count of the bucket with index
      # `offset + k`. The layout of an OpenTelemetry ExponentialHistogramDataPoint's
      # `positive` and `negative` fields.
      class Buckets
        attr_reader :offset, :counts

        def initialize
          @offset = 0
          @counts = []
        end

        def initialize_copy(other)
          super
          @counts = other.counts.dup
        end

        # A clone of frozen buckets has frozen counts too.
        def initialize_clone(other, freeze: nil)
          super
          @counts.freeze if freeze || (freeze.nil? && other.frozen?)
        end

        def freeze
          @counts.freeze
          super
        end

        def empty?
          @counts.empty?
        end

        # Index of the lowest bucket held.
        def low
          @offset
        end

        # Index of the highest bucket held.
        def high
          @offset + @counts.size - 1
        end

        # Adds one to the count of the bucket `index` and returns true when that bucket is in the
        # range held. Returns false, changing nothing, when it is not.
        def increment_held(index)
          position = index - @offset
          return false unless position >= 0 && position < @counts.size

          @counts[position] += 1
          true
        end

        # Adds `amount` to the count of the bucket `index`, extending the range as needed.
        def increment(index, amount = 1)
          if @counts.empty?
            @offset = index
            @counts << 0
          elsif index < @offset
            @counts.unshift(*Array.new(@offset - index, 0))
            @offset = index
          elsif index > high
            @counts.concat(Array.new(index - high, 0))
          end
          @counts[index - @offset] += amount
        end

        # Yields the index and count of each non-empty bucket, lowest index first.
        def each
          @counts.each_with_index { |count, k| yield(@offset + k, count) unless count.zero? }
        end

        # Yields the index and count of each non-empty bucket, highest index first.
        def reverse_each
          (@counts.size - 1).downto(0) do |k|
            count = @counts[k]
            yield(@offset + k, count) unless count.zero?
          end
        end

        # Lowers the resolution by `change` scales: bucket `i` becomes bucket `i >> change`.
        def downscale(change)
          return if change.zero? || empty?

          old_offset = @offset
          old_counts = @counts
          @offset    = old_offset >> change
          @counts    = Array.new(((old_offset + old_counts.size - 1) >> change) - @offset + 1, 0)
          old_counts.each_with_index { |count, k| @counts[((old_offset + k) >> change) - @offset] += count }
        end

        # Adds the counts of `other`, whose bucket index `i` is bucket `i >> change` here.
        def merge(other, change)
          other.each { |index, count| increment(index >> change, count) }
        end
      end

      attr_reader :scale, :count, :sum, :min, :max, :zero_count, :positive, :negative

      def initialize
        self.scale  = MAX_SCALE
        @count      = 0
        @sum        = 0.0
        @min        = nil
        @max        = nil
        @zero_count = 0
        @positive   = Buckets.new
        @negative   = Buckets.new
      end

      def initialize_copy(other)
        super
        @positive = other.positive.dup
        @negative = other.negative.dup
      end

      # A clone of a frozen histogram has frozen buckets too.
      def initialize_clone(other, freeze: nil)
        super
        return unless freeze || (freeze.nil? && other.frozen?)

        @positive.freeze
        @negative.freeze
      end

      def freeze
        @positive.freeze
        @negative.freeze
        super
      end

      def empty?
        @count.zero?
      end

      # Records a value. Returns whether it was recorded: anything other than a real Numeric that
      # is finite as a Float (NaN, Infinity, 10**400, Complex, nil, a String, ...) is ignored.
      #
      # The sum is a Float: once the values add up to more than Float::MAX it is Infinity, while
      # count, min, max and the buckets stay right. A consumer that needs a finite sum checks
      # `sum.finite?`.
      def record(value)
        unless value.is_a?(Float)
          return false unless value.is_a?(Numeric) && value.real?

          value = value.to_f
        end
        return false unless value.finite?

        @count += 1
        @sum   += value
        @min = value if @min.nil? || value < @min
        @max = value if @max.nil? || value > @max
        if value > 0.0
          add(@positive, value)
        elsif value < 0.0
          add(@negative, -value)
        else
          @zero_count += 1
        end
        true
      end

      # Adds the values recorded in `other` to this histogram, lowering the scale of this histogram
      # to the lower of the two scales, and further if the combined range needs it. `other` is not
      # changed. Returns self.
      def merge(other)
        return self if other.empty?

        # A histogram holding only zeros has no buckets, so its scale does not matter.
        target = other.positive.empty? && other.negative.empty? ? @scale : [@scale, other.scale].min
        change = [
          merged_range_change(@positive, other.positive, other.scale, target),
          merged_range_change(@negative, other.negative, other.scale, target)
        ].max
        downscale(@scale - target + change)
        @positive.merge(other.positive, other.scale - @scale)
        @negative.merge(other.negative, other.scale - @scale)

        @count      += other.count
        @sum        += other.sum
        @zero_count += other.zero_count
        @min = other.min if @min.nil? || other.min < @min
        @max = other.max if @max.nil? || other.max > @max
        self
      end

      # Yields lower, upper and count for each non-empty bucket in ascending order of value:
      # the negative buckets, then the zero bucket (0.0, 0.0), then the positive buckets.
      # A bucket holds the values in (lower, upper]. The bounds are narrowed to the recorded min
      # and max, so that the first and last buckets do not reach past the values recorded. A bound
      # that underflows to zero (at a low scale, below the smallest subnormal Float) is given as the
      # smallest positive Float, 0.0.next_float, or its negative, so that no bound of a positive or
      # negative bucket is zero. A subnormal bound is given as it is.
      # Returns an Enumerator without a block.
      def each_bucket
        return enum_for(:each_bucket) unless block_given?

        @negative.reverse_each do |index, count|
          yield(narrow(-bound(index + 1)), narrow(-bound(index)), count)
        end
        yield(0.0, 0.0, @zero_count) unless @zero_count.zero?
        @positive.each do |index, count|
          yield(narrow(bound(index)), narrow(bound(index + 1)), count)
        end
      end

      # Estimated value at quantile `probability` (0..1): finds the bucket holding that rank and interpolates
      # geometrically inside it. The result lies within min..max. Returns nil when empty.
      def quantile(probability)
        unless probability.is_a?(Numeric) && probability.real? && probability.between?(0, 1)
          raise(ArgumentError, "Quantile must be in 0..1, not #{probability.inspect}")
        end
        return if empty?

        rank = probability * @count
        seen = 0
        each_bucket do |lower, upper, count|
          return interpolate(lower, upper, (rank - seen).fdiv(count)) if seen + count >= rank

          seen += count
        end
        @max
      end

      # Counts for explicit buckets with the given ascending upper `bounds`, as OpenTelemetry
      # explicit-bucket histograms define them: element k counts the values in
      # (bounds[k - 1], bounds[k]], and the last element, at index bounds.size, those above
      # bounds.last. Each exponential bucket goes, whole, to the explicit bucket holding its
      # upper bound (see #each_bucket for its bounds).
      #
      # Exact when every bound is a bucket boundary at the current scale (such as a power of two)
      # or lies outside min..max. A bound inside a bucket splits values that the histogram cannot
      # tell apart: that whole bucket is counted above the bound.
      def explicit_bucket_counts(bounds)
        counts = Array.new(bounds.size + 1, 0)
        each_bucket do |_lower, upper, count|
          counts[bounds.bsearch_index { |bound| bound >= upper } || bounds.size] += count
        end
        counts
      end

      # Estimated sum of the squares of the values recorded, for destinations that derive a
      # standard deviation from it: each bucket's count times the square of its midpoint (see
      # #each_bucket for its bounds), raised to sum**2 / count when below it, since no values with
      # this count and sum have a smaller sum of squares. Exact when every value recorded is the
      # same. 0.0 when empty. Like #sum, it can overflow to Infinity; when #sum is not finite, the
      # estimate is not raised.
      def sum_of_squares
        return 0.0 if empty?

        estimate = 0.0
        each_bucket do |lower, upper, count|
          midpoint  = (lower / 2.0) + (upper / 2.0)
          estimate += count * midpoint * midpoint
        end
        least = @sum * @sum / @count
        least.finite? && least > estimate ? least : estimate
      end

      private

      # Index of the bucket holding the positive, finite `value` at the current scale: its position
      # log2(value) * 2**scale, rounded up, less one. When the position is within EDGE of a
      # boundary, where Math.log2 could have rounded it across, #exact_index_of decides instead.
      def index_of(value)
        position = Math.log2(value) * @factor
        index    = position.ceil - 1
        offset   = position - index
        return index if offset > EDGE && offset < 1.0 - EDGE

        exact_index_of(value)
      end

      # Index of the bucket holding the positive, finite `value` at the current scale, exact at the
      # boundaries: Math.frexp splits the value into its power of two and a mantissa in [1, 2)
      # without rounding, and the mantissa is compared with the boundaries in BOUNDARIES, which
      # #lower_boundary uses too.
      def exact_index_of(value)
        fraction, exponent = Math.frexp(value)
        mantissa = fraction * 2.0
        exponent -= 1
        if @scale.negative?
          exponent -= 1 unless mantissa > 1.0
          return exponent >> -@scale
        end

        boundaries = BOUNDARIES[@scale]
        # Number of boundaries below the mantissa: a value on a boundary belongs to the bucket below.
        above = boundaries.bsearch_index { |boundary| boundary >= mantissa } || boundaries.size
        (exponent << @scale) + above - 1
      end

      # Lower boundary of the bucket `index` at the current scale: base**index.
      def lower_boundary(index)
        return Math.ldexp(1.0, index << -@scale) if @scale.negative?

        Math.ldexp(BOUNDARIES[@scale][index & ((1 << @scale) - 1)], index >> @scale)
      end

      # Smallest positive Float (a subnormal), the bound given for a boundary that underflows to zero.
      SMALLEST = 0.0.next_float
      private_constant :SMALLEST

      # Lower boundary of the bucket `index`, never zero: the bound #each_bucket gives.
      def bound(index)
        boundary = lower_boundary(index)
        boundary.zero? ? SMALLEST : boundary
      end

      def add(buckets, magnitude)
        index = index_of(magnitude)
        return if buckets.increment_held(index)

        unless buckets.empty?
          low    = buckets.low
          high   = buckets.high
          change = range_change([index, low].min, [index, high].max)
          if change.positive?
            downscale(change)
            index >>= change
          end
        end
        buckets.increment(index)
      end

      # How many scales to lower the current one by so that buckets low..high fit in MAX_SIZE.
      def range_change(low, high)
        fit_change(low, high, @scale)
      end

      # How many scales below `target` the combined range of `mine` and `theirs` needs.
      def merged_range_change(mine, theirs, their_scale, target)
        return 0 if theirs.empty?

        low  = theirs.low >> (their_scale - target)
        high = theirs.high >> (their_scale - target)
        unless mine.empty?
          low  = [low, mine.low >> (@scale - target)].min
          high = [high, mine.high >> (@scale - target)].max
        end
        fit_change(low, high, target)
      end

      # How many scales below `scale` buckets low..high (at `scale`) need to fit in MAX_SIZE,
      # never going below MIN_SCALE, where every Float fits.
      def fit_change(low, high, scale)
        change = 0
        change += 1 while (high >> change) - (low >> change) >= MAX_SIZE
        [change, scale - MIN_SCALE].min
      end

      def downscale(change)
        return unless change.positive?

        @positive.downscale(change)
        @negative.downscale(change)
        self.scale = @scale - change
      end

      # Sets the scale and the factor #index_of multiplies by, 2**scale, together.
      def scale=(scale)
        @scale  = scale
        @factor = 2.0**scale
      end

      def narrow(value)
        value.clamp(@min, @max)
      end

      # The value `fraction` (0..1) of the way through (lower, upper], geometrically. Both bounds
      # have the same sign: #each_bucket gives no zero bound except for the zero bucket, where
      # they are equal.
      def interpolate(lower, upper, fraction)
        return lower if lower == upper || fraction <= 0
        return upper if fraction >= 1

        value = lower.positive? ? lower * ((upper / lower)**fraction) : -(-upper * ((lower / upper)**(1.0 - fraction)))
        narrow(value)
      end
    end
  end
end
