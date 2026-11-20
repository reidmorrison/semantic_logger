module SemanticLogger
  module Metric
    # Aggregates the metrics recorded during the current interval, on the threads that record them,
    # and hands them over as a frozen Snapshot on #collect.
    #
    # A series is identified by its kind, name, unit, dimensions and whether it is internal (see
    # Snapshot::Point#identity). The unit is part of the identity so that values in two units never
    # end up in one sum or histogram; likewise a name used with two kinds makes two series.
    #
    # It does not judge the values it is given: the caller drops and reports the ones it rejects,
    # such as negative counter amounts. Whatever reaches it is never allowed to raise: a value that
    # is not a finite real Numeric, an unknown kind, or dimensions that are not a Hash, are ignored.
    #
    # Thread-safe: one Mutex guards the series. In a signal trap, where a Mutex cannot be locked,
    # a record is queued instead and added by the next #record or #collect.
    class Aggregator
      # Most series a metric (kind, name, unit) may have per interval. The values of further
      # dimension sets go to one overflow series with Snapshot::Point::OVERFLOW_DIMENSIONS.
      SERIES_LIMIT = 2000

      # The sum of a counter series. Stays an Integer while every amount is an Integer.
      class Sum
        attr_reader :value

        def initialize
          @value = 0
        end

        def record(amount)
          @value += amount.is_a?(Integer) ? amount : amount.to_f
        end
      end

      # The series of one metric (kind, name, unit, internal) in the current interval, by dimensions.
      class Instrument
        attr_reader :kind, :name, :unit, :internal

        def initialize(kind, name, unit, internal, series_limit)
          @kind         = kind
          @name         = Aggregator.frozen(name)
          @unit         = Aggregator.frozen(unit)
          @internal     = internal
          @series_limit = series_limit
          @plain        = nil
          @series       = {}
          @overflow     = nil
        end

        # Records `value` in the series for `dimensions`, adding the series if new.
        def record(value, dimensions)
          if dimensions.nil? || dimensions.empty?
            (@plain ||= new_aggregate).record(value)
          else
            (@series[dimensions] || add_series(dimensions)).record(value)
          end
        end

        # Yields a Snapshot::Point for each series.
        def each_point
          yield(point(Snapshot::Point::EMPTY_DIMENSIONS, @plain)) if @plain
          @series.each_pair { |dimensions, aggregate| yield(point(dimensions, aggregate)) }
          yield(point(Snapshot::Point::OVERFLOW_DIMENSIONS, @overflow)) if @overflow
        end

        private

        def add_series(dimensions)
          if dimensions == Snapshot::Point::OVERFLOW_DIMENSIONS || @series.size + (@plain ? 1 : 0) >= @series_limit
            return @overflow ||= new_aggregate
          end

          @series[Aggregator.frozen_dimensions(dimensions)] = new_aggregate
        end

        def new_aggregate
          @kind == :counter ? Sum.new : ExponentialHistogram.new
        end

        def point(dimensions, aggregate)
          Snapshot::Point.new(
            kind:       @kind,
            name:       @name,
            unit:       @unit,
            dimensions: dimensions,
            value:      @kind == :counter ? aggregate.value : aggregate,
            internal:   @internal
          )
        end
      end

      # A frozen copy of the dimensions, whose String keys and values cannot change under it either.
      def self.frozen_dimensions(dimensions)
        dimensions.to_h { |key, value| [frozen(key), frozen(value)] }.freeze
      end

      # The value itself, or a frozen copy of it when it is a String that is not frozen.
      def self.frozen(value)
        value.is_a?(String) && !value.frozen? ? value.dup.freeze : value
      end

      attr_reader :series_limit

      # series_limit: Most series a metric may have per interval (see SERIES_LIMIT).
      # now:          Start of the first interval.
      def initialize(series_limit: SERIES_LIMIT, now: Time.now)
        @series_limit = series_limit
        @mutex        = Mutex.new
        @pending      = Thread::Queue.new
        start(now)
      end

      # Records `value` in the series identified by the other arguments.
      #
      # kind:       :counter adds `value` to the sum of the series; :histogram records it in its histogram.
      # name:       Name of the metric.
      # unit:       Unit of the values, such as "s" or "By". Part of the identity of the series.
      # dimensions: Hash of the dimensions of the series. nil and {} are the same series. A frozen copy is kept.
      # internal:   Whether it is one of Semantic Logger's own metrics.
      #
      # Returns whether it was recorded (or queued, in a signal trap).
      def record(kind, name, value, unit: nil, dimensions: nil, internal: false)
        return false unless recordable?(kind, value, dimensions)

        @mutex.synchronize do
          add_pending unless @pending.empty?
          instrument(kind, name, unit, internal).record(value, dimensions)
        end
        true
      rescue ThreadError
        # In a signal trap. Thread::Queue#push does not lock a Mutex.
        dimensions = Aggregator.frozen_dimensions(dimensions) if dimensions
        @pending.push([kind, name, value, unit, dimensions, internal])
        true
      end

      # Returns a frozen Snapshot of the series recorded since the start of the interval, up to `now`,
      # and starts the next interval at `now`. The snapshot is empty when nothing was recorded.
      def collect(now = Time.now)
        counters, histograms, others, start_time = @mutex.synchronize do
          add_pending unless @pending.empty?
          taken = [@counters, @histograms, @others, @start_time]
          start(now)
          taken
        end
        points = []
        [counters, histograms, others].each do |instruments|
          instruments.each_value { |instrument| instrument.each_point { |point| points << point } }
        end
        Snapshot.new(start_time: start_time, end_time: now, points: points.freeze)
      end

      # Discards everything recorded, queued records included, and starts a new interval at `now`.
      def reset(now = Time.now)
        @mutex.synchronize do
          @pending.clear
          start(now)
        end
        nil
      end

      private

      def start(now)
        @start_time = now
        # The first metric (kind, name) with a given name, whatever its unit or whether it is internal.
        @counters   = {}
        @histograms = {}
        # The other metrics with the same kind and name, by [kind, name, unit, internal].
        @others     = {}
      end

      def recordable?(kind, value, dimensions)
        %i[counter histogram].include?(kind) && value.is_a?(Numeric) && value.real? && value.finite? &&
          (dimensions.nil? || dimensions.is_a?(Hash))
      end

      # The instrument for the metric, added if new. Under the lock.
      def instrument(kind, name, unit, internal)
        instruments = kind == :counter ? @counters : @histograms
        first       = instruments[name]
        return first if first && first.unit == unit && first.internal == internal

        return instruments[name] = Instrument.new(kind, name, unit, internal, @series_limit) unless first

        key = [kind, name, unit, internal]
        @others[key] ||= Instrument.new(kind, name, unit, internal, @series_limit)
      end

      # Adds the records queued in signal traps. Under the lock.
      def add_pending
        until @pending.empty?
          kind, name, value, unit, dimensions, internal = @pending.pop(true)
          instrument(kind, name, unit, internal).record(value, dimensions)
        end
      rescue ThreadError
        # Emptied by another thread in between: nothing left.
      end
    end
  end
end
