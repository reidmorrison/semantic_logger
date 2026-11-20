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
    # `freeze` also freezes the buckets.
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
        @scale      = MAX_SCALE
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

      def freeze
        @positive.freeze
        @negative.freeze
        super
      end

      def empty?
        @count.zero?
      end

      # Records a value. Returns whether it was recorded: anything other than a finite real
      # Numeric (NaN, Infinity, Complex, nil, a String, ...) is ignored.
      def record(value)
        return false unless value.is_a?(Numeric) && value.real?

        value = value.to_f
        return false unless value.finite?

        @count += 1
        @sum   += value
        @min = value if @min.nil? || value < @min
        @max = value if @max.nil? || value > @max
        if value.positive?
          add(@positive, value)
        elsif value.negative?
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

        target = [@scale, other.scale].min
        change = [
          merged_range_change(@positive, other.positive, other.scale, target),
          merged_range_change(@negative, other.negative, other.scale, target)
        ].max
        downscale(@scale - [target - change, MIN_SCALE].max)
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
      # and max, so that the first and last buckets do not reach past the values recorded.
      # Returns an Enumerator without a block.
      def each_bucket
        return enum_for(:each_bucket) unless block_given?

        @negative.reverse_each do |index, count|
          yield(narrow(-lower_boundary(index + 1)), narrow(-lower_boundary(index)), count)
        end
        yield(0.0, 0.0, @zero_count) unless @zero_count.zero?
        @positive.each do |index, count|
          yield(narrow(lower_boundary(index)), narrow(lower_boundary(index + 1)), count)
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
      # midpoint (see #each_bucket for its bounds).
      def explicit_bucket_counts(bounds)
        counts = Array.new(bounds.size + 1, 0)
        each_bucket do |lower, upper, count|
          midpoint = (lower + upper) / 2.0
          counts[bounds.bsearch_index { |bound| bound >= midpoint } || bounds.size] += count
        end
        counts
      end

      private

      # Index of the bucket holding the positive, finite `value` at the current scale.
      #
      # Exact at the boundaries: Math.frexp splits the value into its power of two and a mantissa
      # in [1, 2) without rounding, and the mantissa is compared with the boundaries in
      # BOUNDARIES, which #lower_boundary uses too.
      def index_of(value)
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

      def add(buckets, magnitude)
        index = index_of(magnitude)
        unless buckets.empty?
          change = range_change([buckets.low, index].min, [buckets.high, index].max)
          if change.positive?
            downscale(change)
            index >>= change
          end
        end
        buckets.increment(index)
      end

      # How many scales to lower the current one by so that buckets low..high fit in MAX_SIZE.
      def range_change(low, high)
        change = 0
        change += 1 while (high >> change) - (low >> change) >= MAX_SIZE
        [change, @scale - MIN_SCALE].min
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
        change = 0
        change += 1 while (high >> change) - (low >> change) >= MAX_SIZE
        change
      end

      def downscale(change)
        return unless change.positive?

        @positive.downscale(change)
        @negative.downscale(change)
        @scale -= change
      end

      def narrow(value)
        value.clamp(@min, @max)
      end

      # The value `fraction` (0..1) of the way through (lower, upper], geometrically.
      def interpolate(lower, upper, fraction)
        return lower if lower == upper || fraction <= 0
        return upper if fraction >= 1

        value =
          if lower.negative?
            -(-upper * ((lower / upper)**(1.0 - fraction)))
          else
            lower * ((upper / lower)**fraction)
          end
        narrow(value)
      end
    end
  end
end
