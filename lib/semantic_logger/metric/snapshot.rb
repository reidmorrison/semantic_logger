module SemanticLogger
  module Metric
    # The metrics aggregated over one interval, from `start_time` to `end_time`: a frozen value
    # holding one Point per series.
    #
    # A metric appender that writes less often than the snapshots arrive merges them with #merge
    # until its own interval has passed.
    class Snapshot
      include Enumerable

      EMPTY_POINTS = [].freeze

      # The aggregate of one series over the interval of its snapshot. Frozen.
      #
      # A series is identified by its kind, name, unit, dimensions and whether it is internal (see #identity):
      # the same name used with two kinds, or two units, makes two series.
      class Point
        # The dimensions of the series that holds the values of the dimension sets beyond the cardinality
        # limit of a metric, as OpenTelemetry names it.
        OVERFLOW_DIMENSIONS = {"otel.metric.overflow" => true}.freeze

        EMPTY_DIMENSIONS = {}.freeze

        # kind:       :counter or :histogram.
        # name:       Name of the metric.
        # unit:       Unit of the values, such as "s" or "By", or nil.
        # dimensions: Frozen Hash of the dimensions of the series, empty when it has none.
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

      attr_reader :start_time, :end_time, :points

      # Takes a frozen copy of `points` (an Array of Point) unless already frozen.
      def initialize(start_time:, end_time:, points: EMPTY_POINTS)
        @start_time = start_time
        @end_time   = end_time
        @points     = points.frozen? ? points : points.dup.freeze
        freeze
      end

      def empty?
        @points.empty?
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
      # in both are merged (see Point#merge), those in only one are kept as they are.
      def merge(later)
        merged = {}
        @points.each { |point| merged[point.identity] = point }
        later.points.each do |point|
          identity        = point.identity
          earlier         = merged[identity]
          merged[identity] = earlier ? earlier.merge(point) : point
        end
        Snapshot.new(start_time: @start_time, end_time: later.end_time, points: merged.values)
      end

      # Returns this snapshot without Semantic Logger's own metrics, itself when it holds none.
      def without_internal
        return self unless @points.any?(&:internal?)

        Snapshot.new(start_time: @start_time, end_time: @end_time, points: @points.reject(&:internal?))
      end

      def inspect
        "#<#{self.class.name} #{@start_time}..#{@end_time} points: #{@points.size}>"
      end
    end
  end
end
