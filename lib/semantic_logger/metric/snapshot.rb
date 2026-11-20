module SemanticLogger
  module Metric
    # The metrics aggregated over one interval, from `start_time` to `end_time`: a frozen value
    # holding one Point per series.
    #
    # A metric appender that writes less often than the snapshots arrive merges them with #merge
    # until its own interval has passed.
    #
    # It also says what the Aggregator dropped during the interval, for its collector to report:
    # #dropped_by_name_limit and #first_name_dropped for records of names beyond the limit of
    # names per interval, #dropped_by_conflict for records of a name with a kind or unit other
    # than the one the name was first recorded with, and #dropped_by_internal_conflict for the
    # same among Semantic Logger's own metrics.
    class Snapshot
      include Enumerable

      EMPTY_POINTS = [].freeze
      EMPTY_COUNTS = {}.freeze

      # The aggregate of one series over the interval of its snapshot. Frozen.
      #
      # A series is identified by its kind, name, unit, dimensions and whether it is internal (see #identity).
      # Within one interval the Aggregator gives a name one kind and one unit; points of a name with two
      # kinds, or two units, meet only when snapshots of different intervals are merged, and stay two series.
      class Point
        # The dimensions of the series that holds the values of the dimension sets beyond the cardinality
        # limit of a metric, as OpenTelemetry names it.
        OVERFLOW_DIMENSIONS = {"otel.metric.overflow" => true}.freeze

        EMPTY_DIMENSIONS = {}.freeze

        # kind:       :counter or :histogram.
        # name:       Name of the metric.
        # unit:       Unit of the values, such as "s" or "By", or nil.
        # dimensions: Frozen Hash of the dimensions of the series, empty when it has none. From the
        #             Aggregator, normalized: frozen String keys, Symbol and non-scalar values as
        #             Strings (see Aggregator).
        # value:      For a counter the sum of its amounts (Integer while every amount was an Integer,
        #             otherwise a Float); for a histogram a frozen ExponentialHistogram.
        # internal:   Whether it is one of Semantic Logger's own metrics.
        attr_reader :kind, :name, :unit, :dimensions, :value, :internal

        # Freezes the value, and takes a frozen copy of the dimensions unless already frozen.
        def initialize(kind:, name:, value:, unit: nil, dimensions: nil, internal: false)
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
          [@kind, @name, @unit, @internal, @dimensions]
        end

        # Returns a new point for the same series, holding the values of this point and of `later`:
        # counter sums are added, histograms merged into a copy of this one.
        def merge(later)
          value = counter? ? @value + later.value : @value.dup.merge(later.value)
          Point.new(kind: @kind, name: @name, unit: @unit, dimensions: @dimensions, value: value, internal: @internal)
        end

        def inspect
          "#<#{self.class.name} #{@kind} #{@name.inspect}#{" (#{@unit})" if @unit} #{@dimensions.inspect}" \
            "#{' internal' if @internal}>"
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
      #                        metric names as the Aggregator allows.
      # first_name_dropped:    Name of the first of those records, or nil.
      # dropped_by_conflict:   Frozen Hash of the number of records dropped, by metric name, because
      #                        their kind or unit was not the one that name was first recorded
      #                        with in the interval (the one its points have).
      # dropped_by_internal_conflict:
      #                        The same, for Semantic Logger's own metrics, counted apart since an
      #                        internal metric may share its name with an application metric.
      attr_reader :start_time, :end_time, :points, :dropped_by_name_limit, :first_name_dropped, :dropped_by_conflict,
                  :dropped_by_internal_conflict

      # Takes frozen copies of `points` (an Array of Point) and of the Hashes of records dropped unless
      # already frozen.
      def initialize(start_time:, end_time:, points: EMPTY_POINTS, dropped_by_name_limit: 0, first_name_dropped: nil,
                     dropped_by_conflict: EMPTY_COUNTS, dropped_by_internal_conflict: EMPTY_COUNTS)
        @start_time                   = start_time
        @end_time                     = end_time
        @points                       = frozen(points)
        @dropped_by_name_limit        = dropped_by_name_limit
        @first_name_dropped           = first_name_dropped
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
      # of records dropped are added; the first name dropped is the earliest.
      def merge(later)
        merged = {}
        [@points, later.points].each do |points|
          points.each do |point|
            identity         = point.identity
            earlier          = merged[identity]
            merged[identity] = earlier ? earlier.merge(point) : point
          end
        end
        Snapshot.new(
          start_time:                   @start_time,
          end_time:                     later.end_time,
          points:                       merged.values.freeze,
          dropped_by_name_limit:        @dropped_by_name_limit + later.dropped_by_name_limit,
          first_name_dropped:           @first_name_dropped || later.first_name_dropped,
          dropped_by_conflict:          add_counts(@dropped_by_conflict, later.dropped_by_conflict),
          dropped_by_internal_conflict: add_counts(@dropped_by_internal_conflict, later.dropped_by_internal_conflict)
        )
      end

      # Returns this snapshot without Semantic Logger's own metrics, itself when it holds none.
      def without_internal
        return self unless @points.any?(&:internal?)

        Snapshot.new(
          start_time:                   @start_time,
          end_time:                     @end_time,
          points:                       @points.reject(&:internal?).freeze,
          dropped_by_name_limit:        @dropped_by_name_limit,
          first_name_dropped:           @first_name_dropped,
          dropped_by_conflict:          @dropped_by_conflict,
          dropped_by_internal_conflict: @dropped_by_internal_conflict
        )
      end

      def inspect
        "#<#{self.class.name} #{@start_time}..#{@end_time} points: #{@points.size}>"
      end

      private

      def frozen(value)
        value.frozen? ? value : value.dup.freeze
      end

      def add_counts(counts, more)
        return counts if more.empty?
        return more if counts.empty?

        counts.merge(more) { |_, a, b| a + b }.freeze
      end
    end
  end
end
