module SemanticLogger
  module Metric
    # The metrics aggregated over one interval, from `start_time` to `end_time`: a frozen value
    # holding one Point per series.
    #
    # A metric appender that writes less often than the snapshots arrive merges them with #merge
    # until its own interval has passed.
    #
    # It also says what the Aggregator dropped during the interval, for its collector to report:
    # #dropped_by_name_limit, #first_name_dropped and #first_scope_dropped for records of metrics
    # beyond the limit of metrics per interval, #dropped_by_conflict for records of a name with a kind or unit other
    # than the one the name was first recorded with, and #dropped_by_internal_conflict for the
    # same among Semantic Logger's own metrics.
    class Snapshot
      include Enumerable

      EMPTY_POINTS = [].freeze
      EMPTY_COUNTS = {}.freeze

      # The aggregate of one series over the interval of its snapshot. Frozen.
      #
      # A series is identified by its scope, kind, name, unit, dimensions and whether it is internal (see
      # #identity). Within one interval the Aggregator gives a name one kind and one unit, in every scope;
      # points of a name with two kinds, or two units, meet only when snapshots of different intervals are
      # merged, and stay two series.
      class Point
        # The dimensions of the series that holds the values of the dimension sets beyond the cardinality
        # limit of a metric, as OpenTelemetry names it.
        OVERFLOW_DIMENSIONS = {"otel.metric.overflow" => true}.freeze

        EMPTY_DIMENSIONS = {}.freeze

        # scope:      Name of the logger that recorded it, a frozen String, as the instrumentation scope
        #             (the meter) of an OpenTelemetry metric is; nil for Semantic Logger's own metrics, and
        #             once the scopes of a snapshot are merged (see Snapshot#without_scopes).
        # kind:       :counter or :histogram.
        # name:       Name of the metric.
        # unit:       Unit of the values, such as "s" or "By", or nil.
        # dimensions: Frozen Hash of the dimensions of the series, empty when it has none. From the
        #             Aggregator, normalized: frozen String keys, Symbol and non-scalar values as
        #             Strings (see Aggregator).
        # value:      For a counter the sum of its amounts (Integer while every amount was an Integer,
        #             otherwise a Float); for a histogram a frozen ExponentialHistogram.
        # internal:   Whether it is one of Semantic Logger's own metrics.
        attr_reader :scope, :kind, :name, :unit, :dimensions, :value, :internal

        # Freezes the value, and takes a frozen copy of the dimensions unless already frozen. An internal
        # point has no scope.
        def initialize(kind:, name:, value:, unit: nil, dimensions: nil, internal: false, scope: nil)
          @scope      = internal || scope.nil? ? nil : Aggregator.frozen(scope)
          @kind       = kind
          @name       = name
          @unit       = unit
          @dimensions = dimensions.nil? || dimensions.empty? ? EMPTY_DIMENSIONS : frozen(dimensions)
          @value      = value.freeze
          @internal   = internal ? true : false
          freeze
        end

        def counter?
          @kind == :counter
        end

        def histogram?
          @kind == :histogram
        end

        def internal?
          @internal
        end

        # Whether this series holds the values of the dimension sets beyond the cardinality limit of its metric.
        def overflow?
          @dimensions == OVERFLOW_DIMENSIONS
        end

        # What identifies the series of this point: points of two snapshots with the same identity are
        # the same series, over different intervals.
        def identity
          [@scope, @kind, @name, @unit, @internal, @dimensions]
        end

        # Returns a new point for the same series without its scope, or itself when it has none (see
        # Snapshot#without_scopes).
        def without_scope
          return self if @scope.nil?

          Point.new(kind: @kind, name: @name, unit: @unit, dimensions: @dimensions, value: @value, internal: @internal)
        end

        # Returns a new point for the same series, holding the values of this point and of `later`:
        # counter sums are added, histograms merged into a copy of this one.
        def merge(later)
          value = counter? ? @value + later.value : @value.dup.merge(later.value)
          Point.new(kind: @kind, name: @name, unit: @unit, dimensions: @dimensions, value: value, internal: @internal,
                    scope: @scope)
        end

        # Returns a new point for the series whose dimensions are these with the value of each dimension
        # whose key is sensitive replaced, as the redactor answers for that key (see
        # Redactor#replacement_for), or itself when none is sensitive, or when it is one of Semantic
        # Logger's own metrics or the overflow series, whose dimensions it chose itself. Only values are
        # replaced, never keys. The dimensions are normalized again, as the Aggregator normalizes them
        # (see Aggregator.normalize_dimensions), since a replacement can be any value.
        #
        # Raises what the redactor raises, so that a point is never given with a sensitive value (see
        # Snapshot#redact, which leaves it out).
        def redact(redactor)
          return self if @internal || @dimensions.empty? || overflow?

          redacted = nil
          @dimensions.each_key do |key|
            replacement = redactor.replacement_for(key)
            next if replacement.nil?

            redacted    ||= @dimensions.dup
            redacted[key] = replacement
          end
          return self unless redacted

          Point.new(kind: @kind, name: @name, unit: @unit, dimensions: Aggregator.normalize_dimensions(redacted),
                    value: @value, internal: @internal, scope: @scope)
        end

        def inspect
          "#<#{self.class.name} #{"#{@scope.inspect} " if @scope}#{@kind} #{@name.inspect}" \
            "#{" (#{@unit})" if @unit} #{@dimensions.inspect}#{' internal' if @internal}>"
        end

        private

        def frozen(dimensions)
          dimensions.frozen? ? dimensions : dimensions.dup.freeze
        end
      end

      # start_time:            Start of the interval.
      # end_time:              End of the interval.
      # points:                The Point of each series.
      # dropped_by_name_limit: Number of records dropped because the interval already had as many
      #                        metrics as the Aggregator allows.
      # first_name_dropped:    Name of the first of those records, or nil.
      # first_scope_dropped:   Scope of the first of those records, or nil.
      # dropped_by_conflict:   Frozen Hash of the number of records dropped, by metric name, because
      #                        their kind or unit was not the one that name was first recorded
      #                        with in the interval (the one its points have).
      # dropped_by_internal_conflict:
      #                        The same, for Semantic Logger's own metrics, counted apart since an
      #                        internal metric may share its name with an application metric.
      attr_reader :start_time, :end_time, :points, :dropped_by_name_limit, :first_name_dropped, :first_scope_dropped,
                  :dropped_by_conflict, :dropped_by_internal_conflict

      # Takes frozen copies of `points` (an Array of Point) and of the Hashes of records dropped unless
      # already frozen.
      def initialize(start_time:, end_time:, points: EMPTY_POINTS, dropped_by_name_limit: 0, first_name_dropped: nil,
                     first_scope_dropped: nil, dropped_by_conflict: EMPTY_COUNTS,
                     dropped_by_internal_conflict: EMPTY_COUNTS)
        @start_time                   = start_time
        @end_time                     = end_time
        @points                       = frozen(points)
        @dropped_by_name_limit        = dropped_by_name_limit
        @first_name_dropped           = first_name_dropped
        @first_scope_dropped          = first_scope_dropped
        @dropped_by_conflict          = frozen(dropped_by_conflict)
        @dropped_by_internal_conflict = frozen(dropped_by_internal_conflict)
        freeze
      end

      # Whether it holds no points. Records dropped are not points.
      def empty?
        @points.empty?
      end

      # Whether any record was dropped in its interval.
      def dropped?
        @dropped_by_name_limit.positive? || !@dropped_by_conflict.empty? || !@dropped_by_internal_conflict.empty?
      end

      def size
        @points.size
      end

      # Yields each point. Returns an Enumerator without a block.
      def each(&)
        return enum_for(:each) { size } unless block_given?

        @points.each(&)
        self
      end

      # Returns a new snapshot from the start of this one to the end of `later`, the snapshot of the
      # interval that follows it (or of a later one), with the points of both: the points of a series
      # are merged (see Point#merge), those of a series in only one are kept as they are. The counts
      # of records dropped are added; the first name dropped, and its scope, are the earliest.
      def merge(later)
        Snapshot.new(
          start_time:                   @start_time,
          end_time:                     later.end_time,
          points:                       merged_points(@points, later.points),
          dropped_by_name_limit:        @dropped_by_name_limit + later.dropped_by_name_limit,
          first_name_dropped:           @first_name_dropped || later.first_name_dropped,
          first_scope_dropped:          @first_name_dropped ? @first_scope_dropped : later.first_scope_dropped,
          dropped_by_conflict:          add_counts(@dropped_by_conflict, later.dropped_by_conflict),
          dropped_by_internal_conflict: add_counts(@dropped_by_internal_conflict, later.dropped_by_internal_conflict)
        )
      end

      # Returns [Hash] for each key that the block gives for a point, such as its name, the kind, unit and
      # value of its points merged: the sum of their counter values, or one histogram merging theirs. The
      # first point of a key gives it its kind and unit: a point of the same key with another kind or unit,
      # possible only once snapshots of several intervals are merged, is left out, as the Aggregator leaves
      # out a record of a name with another kind or unit within one interval.
      #
      # For a destination that keys its metrics by less than the identity of a series (see Point#identity).
      # A histogram is copied once, when a second point merges into it, so that the points are not
      # changed: a value that is still frozen is the point's own.
      def merged_by
        merged = {}
        @points.each do |point|
          key    = yield(point)
          metric = merged[key]
          if metric.nil?
            merged[key] = [point.kind, point.unit, point.value]
          elsif metric[0] == point.kind && metric[1] == point.unit
            metric[2] = merged_value(metric[2], point)
          end
        end
        merged
      end

      # Returns this snapshot without the scopes of its points, itself when none has one: the points of
      # series that differ only by their scope, recorded with the same name and dimensions by the loggers
      # of different classes, are merged into one (see Point#merge), for a destination that has no
      # scopes (see Snapshots#metric_scopes?).
      def without_scopes
        return self if @points.none?(&:scope)

        with_points(merged_points(@points.map(&:without_scope)))
      end

      # Returns this snapshot without Semantic Logger's own metrics, itself when it holds none.
      def without_internal
        return self unless @points.any?(&:internal?)

        with_points(@points.reject(&:internal?))
      end

      # Returns this snapshot with the value of each sensitive dimension of its points replaced (see
      # Point#redact), or itself when none is sensitive. Points whose series become the same, such as
      # two that differed only by the value of a sensitive dimension, are merged into one (see
      # Point#merge), so that every point is still a series of its own, as #merged_by and #merge
      # expect. Takes time in proportion to the number of series, however often each was recorded.
      #
      # A point that cannot be redacted, such as when the sensitive keys raise, is left out, never
      # given with a sensitive value, and what it raised is yielded, so that the caller can count and
      # report it; the other points are kept. Without a block, raises what the first one raised.
      def redact(redactor)
        redacted = nil
        @points.each_with_index do |point, index|
          new_point =
            begin
              point.redact(redactor)
            rescue StandardError => e
              raise unless block_given?

              yield(e)
              nil
            end
          next if redacted.nil? && new_point.equal?(point)

          redacted ||= @points.first(index)
          redacted << new_point if new_point
        end
        redacted ? with_points(merged_points(redacted)) : self
      end

      # Returns this snapshot with only Semantic Logger's own metrics (see Point#internal?), over the
      # same interval and with the same counts of records dropped, such as for an interval whose
      # application metrics cannot be delivered. Itself when it holds no other point.
      def only_internal
        return self if @points.all?(&:internal?)

        with_points(@points.select(&:internal?))
      end

      def inspect
        "#<#{self.class.name} #{@start_time}..#{@end_time} points: #{@points.size}>"
      end

      private

      def frozen(value)
        value.frozen? ? value : value.dup.freeze
      end

      # Returns a copy of this snapshot, over the same interval and with the same counts of records
      # dropped, holding `points` instead.
      def with_points(points)
        Snapshot.new(
          start_time:                   @start_time,
          end_time:                     @end_time,
          points:                       points.freeze,
          dropped_by_name_limit:        @dropped_by_name_limit,
          first_name_dropped:           @first_name_dropped,
          first_scope_dropped:          @first_scope_dropped,
          dropped_by_conflict:          @dropped_by_conflict,
          dropped_by_internal_conflict: @dropped_by_internal_conflict
        )
      end

      # Returns [Array<Point>] one point per series of the lists of points, those of the same series
      # merged in order (see Point#merge).
      def merged_points(*lists)
        merged = {}
        lists.each do |points|
          points.each do |point|
            identity         = point.identity
            earlier          = merged[identity]
            merged[identity] = earlier ? earlier.merge(point) : point
          end
        end
        merged.values.freeze
      end

      # The value merged so far for a key of #merged_by, with that of the point.
      def merged_value(value, point)
        return value + point.value if point.counter?

        (value.frozen? ? value.dup : value).merge(point.value)
      end

      def add_counts(counts, more)
        return counts if more.empty?
        return more if counts.empty?

        counts.merge(more) { |_, a, b| a + b }.freeze
      end
    end
  end
end
