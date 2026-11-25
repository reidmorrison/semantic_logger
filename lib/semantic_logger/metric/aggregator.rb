module SemanticLogger
  module Metric
    # Aggregates the metrics recorded during the current interval, on the threads that record them,
    # and hands them over as a frozen Snapshot on #collect.
    #
    # A series is identified by its scope, kind, name, unit, dimensions and whether it is internal (see
    # Snapshot::Point#identity). The scope of an application metric is the name of the logger that
    # recorded it, as the instrumentation scope (the meter) of an OpenTelemetry metric is, so that the
    # metrics of each class are kept apart; Semantic Logger's own metrics have none. A metric is a name
    # within a scope: the same name recorded by the loggers of two classes is two metrics. A name and
    # a scope are normalized to frozen Strings, so :jobs and "jobs" are one metric. Within an interval
    # a metric has one kind and one unit: the first record of it decides them, and a later record of
    # it with another kind or unit is dropped and counted on the snapshot by its name
    # (Snapshot#dropped_by_conflict, or #dropped_by_internal_conflict for an internal metric). Internal
    # metrics have names of their own: they never conflict with an application metric.
    #
    # Dimensions are normalized, so that the same dimensions written in different ways make one
    # series: keys become frozen Strings ({region: "eu"} and {"region" => "eu"} are one series), and
    # so do Symbol values ({region: :eu} is that series too). Other scalar values (String, Integer,
    # finite Float, true, false, nil) are kept as they are, Strings as frozen copies; an Array of
    # scalars becomes a frozen Array of them, normalized the same way; any other value (a Hash, a
    # non-finite Float, an object) becomes frozen text (see Aggregator.text), as does a key that
    # is neither a String nor a Symbol. A structure becomes text only once the values of its sensitive
    # keys are replaced (see SemanticLogger.sensitive_keys=). A series' dimensions therefore never change after it is
    # added, whatever the caller does to the Hash it passed in.
    #
    # Limits, per interval, so that a mistake in the application cannot exhaust memory:
    # - At most `name_limit` application metrics, a name within a scope each. A record of a further
    #   metric is dropped and counted on the snapshot (Snapshot#dropped_by_name_limit,
    #   #first_name_dropped).
    # - At most `series_limit` dimension sets per metric, the series without dimensions included.
    #   The values of further dimension sets go to one overflow series with
    #   Snapshot::Point::OVERFLOW_DIMENSIONS.
    # The caller of #collect reports what the snapshot says was dropped.
    #
    # Recording slows down, without failing, past these limits: a record whose dimensions are not
    # remembered (see Instrument) normalizes them on every record, about as slow as the first record
    # of a series. That is so for every new dimension set once a metric has `series_limit` series,
    # and for any dimension set once `series_limit * 2` ways of writing them are remembered.
    #
    # It does not judge the values it is given: which values are recordable at all (such as
    # negative counter amounts) is decided before they reach it (see Validator). It only refuses what
    # would make it raise or corrupt its series: an unknown kind, dimensions that are not a Hash, and
    # a value that the Validator would not record either (see Validator.recordable_value?), which it
    # asks rather than judge the value itself. A counter keeps an exact Integer sum, however large,
    # while every amount is an Integer; an amount that would make a Float sum non-finite is dropped,
    # keeping the sum it had.
    #
    # Thread-safe: one Mutex guards the series. In a signal trap, where a Mutex cannot be locked,
    # a record is queued instead and added by the next #record or #collect.
    class Aggregator
      # Most series a metric may have per interval. The values of further dimension sets go to one
      # overflow series with Snapshot::Point::OVERFLOW_DIMENSIONS.
      SERIES_LIMIT = 2000

      # Most application metrics, a name within a scope each, per interval. Records of further metrics are
      # dropped.
      NAME_LIMIT = 2000

      # The sum of a counter series. Stays an Integer while every amount is an Integer.
      class Sum
        attr_reader :value

        def initialize
          @value = 0
        end

        # Adds `amount` and returns true. Returns false, keeping the sum, when the sum is a Float
        # that would no longer be finite.
        def record(amount)
          if amount.is_a?(Integer) && @value.is_a?(Integer)
            @value += amount
          else
            sum = @value + amount.to_f
            return false unless sum.finite?

            @value = sum
          end
          true
        end
      end

      # The series of one metric (scope, kind, name, unit, internal) in the current interval, by dimensions.
      #
      # To find a series without normalizing the dimensions on every record, and without
      # Hash#eql? on a Hash key (slow, since it guards against recursion), it remembers the
      # dimensions it was given as a tree: key, then value, for each pair in the caller's order,
      # ending in a node that holds the aggregate under LEAF. The same dimensions given in another
      # order, or with Symbols for Strings, make another path to the same aggregate. It remembers at
      # most `series_limit * 2` paths; dimensions not remembered are normalized on every record.
      class Instrument
        # Key of the aggregate in the last node of a path.
        LEAF = Object.new.freeze

        attr_reader :scope, :kind, :name, :unit, :internal

        # name:  frozen String (see Aggregator.metric_name).
        # scope: nil, or the name of a logger, normalized as a name is.
        def initialize(kind, name, unit, internal, series_limit, scope: nil)
          @scope        = scope && Aggregator.metric_name(scope)
          @kind         = kind
          @name         = name
          @unit         = Aggregator.frozen(unit)
          @internal     = internal
          @series_limit = series_limit
          # Normalized dimensions => aggregate of the series.
          @series       = {}
          # The tree of the dimensions as callers gave them (see above), and its number of paths.
          @lookup       = {}
          @paths        = 0
          @plain        = nil
          @overflow     = nil
        end

        # Whether records of this kind and unit belong to this metric.
        def accepts?(kind, unit)
          kind == @kind && unit == @unit
        end

        # Records `value` in the series for `dimensions`, adding the series if new. Returns whether
        # it was recorded.
        def record(value, dimensions)
          aggregate =
            if dimensions.nil? || dimensions.empty?
              @plain ||= aggregate_for(Snapshot::Point::EMPTY_DIMENSIONS)
            else
              find(dimensions) || look_up(dimensions)
            end
          aggregate.record(value)
        end

        # Yields a Snapshot::Point for each series.
        def each_point
          @series.each_pair { |dimensions, aggregate| yield(point(dimensions, aggregate)) }
          yield(point(Snapshot::Point::OVERFLOW_DIMENSIONS, @overflow)) if @overflow
        end

        private

        # The aggregate remembered for these dimensions, or nil.
        def find(dimensions)
          node = @lookup
          dimensions.each_pair do |key, value|
            node = node[key]
            break unless node

            node = node[value]
            break unless node
          end
          node && node[LEAF]
        end

        # The aggregate for dimensions not found, remembered for the next record unless their keys
        # or values could change under it (see Aggregator.rememberable?), or too many already are.
        def look_up(dimensions)
          aggregate = aggregate_for(Aggregator.normalize_dimensions(dimensions))
          remember(dimensions, aggregate) if @paths < @series_limit * 2 && Aggregator.rememberable?(dimensions)
          aggregate
        end

        # Hash#[]= keeps a frozen copy of a String key, so the tree holds no String the caller can change.
        def remember(dimensions, aggregate)
          node = @lookup
          dimensions.each_pair do |key, value|
            node = (node[key] ||= {})
            node = (node[value] ||= {})
          end
          node[LEAF] = aggregate
          @paths += 1
        end

        def aggregate_for(dimensions)
          aggregate = @series[dimensions]
          return aggregate if aggregate

          if dimensions == Snapshot::Point::OVERFLOW_DIMENSIONS || @series.size >= @series_limit
            return @overflow ||= new_aggregate
          end

          @series[dimensions] = new_aggregate
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
            internal:   @internal,
            scope:      @scope
          )
        end
      end

      # The dimensions that identify a series: a frozen copy with frozen String keys, Symbol values
      # as Strings, and non-scalar values as Strings (see the class comment).
      def self.normalize_dimensions(dimensions)
        normalized = {}
        dimensions.each_pair { |key, value| normalized[dimension_key(key)] = dimension_value(value) }
        normalized.freeze
      end

      # Whether a series can be found again by these dimensions as given, without normalizing them:
      # when every key is a Symbol or String, and every value a scalar. Any other key or value could
      # change after it is remembered.
      def self.rememberable?(dimensions)
        dimensions.all? do |key, value|
          case key
          when Symbol, String
            scalar?(value)
          else
            false
          end
        end
      end

      # The name of a metric as a frozen String: a Symbol's name, a String frozen and deduplicated,
      # anything else as its text (see .text).
      def self.metric_name(name)
        case name
        when String
          -name
        when Symbol
          name.name
        else
          text(name)
        end
      end

      # Frozen text for a value that is not a scalar, without ever raising: an Array or Hash through
      # Utils.safe_inspect (its #to_s is #inspect, which a deeply nested one would overflow the stack
      # with), anything else by #to_s. When that raises or does not return a String, its class name.
      #
      # A structure, such as a Hash, is first redacted with the sensitive keys, when there are any
      # (see SemanticLogger.sensitive_keys= and Redactor#redact), since its text cannot be redacted
      # afterwards. Only such values come here, and are never remembered (see .rememberable?), so it
      # is redacted on every record, with the sensitive keys of the moment, and a scalar costs nothing more.
      def self.text(value)
        string =
          begin
            redactor = SemanticLogger.redactor
            value    = redactor.redact(value) if redactor
            case value
            when Array, Hash
              Utils.safe_inspect(value)
            else
              value.to_s
            end
          rescue StandardError
            nil
          end
        string = Kernel.instance_method(:class).bind_call(value).to_s unless string.is_a?(String)
        -string
      end

      def self.dimension_key(key)
        case key
        when String
          -key
        when Symbol
          key.name
        else
          text(key)
        end
      end

      def self.dimension_value(value)
        case value
        when String
          -value
        when Symbol
          value.name
        when Array
          return text(value) unless value.all? { |element| scalar?(element) }

          value.map { |element| dimension_value(element) }.freeze
        else
          scalar?(value) ? value : text(value)
        end
      end

      def self.scalar?(value)
        case value
        # Classes rather than true, false and nil: their #=== can be patched (BSON) to call methods on `value`.
        when String, Symbol, Integer, TrueClass, FalseClass, NilClass
          true
        when Float
          value.finite?
        else
          false
        end
      end

      # The value itself, or a frozen copy of it when it is a String that is not frozen.
      def self.frozen(value)
        value.is_a?(String) && !value.frozen? ? value.dup.freeze : value
      end

      private_class_method :dimension_key, :dimension_value, :scalar?, :text

      attr_reader :series_limit, :name_limit

      # series_limit: Most series a metric may have per interval (see SERIES_LIMIT).
      # name_limit:   Most application metrics per interval (see NAME_LIMIT).
      # now:          Start of the first interval.
      def initialize(series_limit: SERIES_LIMIT, name_limit: NAME_LIMIT, now: Time.now)
        @series_limit = series_limit
        @name_limit   = name_limit
        @mutex        = Mutex.new
        @pending      = Thread::Queue.new
        start(now)
      end

      # Records `value` in the series identified by the other arguments.
      #
      # kind:       :counter adds `value` to the sum of the series; :histogram records it in its histogram.
      # name:       Name of the metric.
      # unit:       Unit of the values, such as "s" or "By". The first record of a name in an
      #             interval decides its unit, as it does its kind.
      # dimensions: Hash of the dimensions of the series. nil and {} are the same series. Normalized
      #             (see the class comment).
      # internal:   Whether it is one of Semantic Logger's own metrics, which have no scope.
      # scope:      Name of the logger that recorded it, or nil (see the class comment). A String is
      #             normalized only when its metric is added, so that a record costs no more for it.
      #
      # Returns whether it was recorded. In a signal trap, true means only that it was queued: when
      # it is added, it can still be dropped (name limit, or another kind or unit for its metric).
      def record(kind, name, value, unit: nil, dimensions: nil, internal: false, scope: nil)
        internal = internal ? true : false
        return false unless recordable?(kind, value, dimensions)

        name  = Aggregator.metric_name(name)
        scope = scope_key(scope, internal)
        begin
          @mutex.lock
        rescue ThreadError
          # In a signal trap, where a Mutex cannot be locked: queue it, with frozen copies of what
          # the caller could change. Thread::Queue#push does not lock a Mutex.
          dimensions = Aggregator.normalize_dimensions(dimensions) if dimensions
          scope      = Aggregator.metric_name(scope) if scope
          @pending.push([kind, name, value, Aggregator.frozen(unit), dimensions, internal, scope])
          return true
        end
        begin
          add_pending unless @pending.empty?
          instrument = instrument(kind, name, unit, internal, scope)
          instrument ? instrument.record(value, dimensions) : false
        ensure
          @mutex.unlock
        end
      end

      # Returns a frozen Snapshot of the series recorded since the start of the interval, up to `now`,
      # and of the records dropped, and starts the next interval at `now`. The snapshot is empty when
      # nothing was recorded.
      def collect(now = Time.now)
        instruments, internal_instruments, start_time, dropped_by_name_limit, first_name_dropped, dropped_by_conflict,
          dropped_by_internal_conflict = @mutex.synchronize do
            add_pending unless @pending.empty?
            taken = [@instruments, @internal_instruments, @start_time, @dropped_by_name_limit, @first_name_dropped,
                     @dropped_by_conflict, @dropped_by_internal_conflict]
            start(now)
            taken
          end
        points = []
        instruments.each_value do |by_name|
          by_name.each_value { |instrument| instrument.each_point { |point| points << point } }
        end
        internal_instruments.each_value { |instrument| instrument.each_point { |point| points << point } }
        Snapshot.new(
          start_time:                   start_time,
          end_time:                     now,
          points:                       points.freeze,
          dropped_by_name_limit:        dropped_by_name_limit,
          first_name_dropped:           first_name_dropped,
          dropped_by_conflict:          dropped_by_conflict.freeze,
          dropped_by_internal_conflict: dropped_by_internal_conflict.freeze
        )
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
        @start_time            = now
        # Application metrics by scope, then name, and their number; internal metrics by name.
        @instruments           = {}
        @metrics               = 0
        @internal_instruments  = {}
        @dropped_by_name_limit = 0
        @first_name_dropped    = nil
        @dropped_by_conflict   = {}
        @dropped_by_internal_conflict = {}
      end

      # Whether recording it is safe; see the class comment.
      def recordable?(kind, value, dimensions)
        %i[counter histogram].include?(kind) && (dimensions.nil? || dimensions.is_a?(Hash)) &&
          Validator.recordable_value?(kind, value)
      end

      # The scope of a record as a key of the instruments: nil for an internal metric, a String as it
      # is, since a Hash keeps a frozen copy of a String key, and anything else normalized as a name is.
      def scope_key(scope, internal)
        return nil if internal || scope.nil?

        scope.is_a?(String) ? scope : Aggregator.metric_name(scope)
      end

      # The instrument a record of this metric goes to, added if new; nil, counting the record as
      # dropped, when the metric is beyond the name limit or was first recorded with another kind or
      # unit. Under the lock.
      def instrument(kind, name, unit, internal, scope)
        instruments = internal ? @internal_instruments : @instruments[scope]
        instrument  = instruments&.[](name)
        if instrument.nil?
          internal ? add_internal_instrument(kind, name, unit) : add_instrument(kind, name, unit, scope)
        elsif instrument.accepts?(kind, unit)
          instrument
        else
          drop_conflict(name, internal ? @dropped_by_internal_conflict : @dropped_by_conflict)
        end
      end

      # Adds an application metric, unless the interval already has as many as the name limit allows.
      def add_instrument(kind, name, unit, scope)
        return drop_name(name) if @metrics >= @name_limit

        @metrics += 1
        (@instruments[scope] ||= {})[name] = Instrument.new(kind, name, unit, false, @series_limit, scope: scope)
      end

      def add_internal_instrument(kind, name, unit)
        @internal_instruments[name] = Instrument.new(kind, name, unit, true, @series_limit)
      end

      def drop_name(name)
        @dropped_by_name_limit += 1
        @first_name_dropped ||= name
        nil
      end

      def drop_conflict(name, counts)
        counts[name] = counts.fetch(name, 0) + 1
        nil
      end

      # Adds the records queued in signal traps. Under the lock.
      def add_pending
        until @pending.empty?
          kind, name, value, unit, dimensions, internal, scope = @pending.pop(true)
          instrument(kind, name, unit, internal, scope)&.record(value, dimensions)
        end
      rescue ThreadError
        # Emptied by another thread in between: nothing left.
      end
    end
  end
end
