module SemanticLogger
  module Metric
    # Internal: knows which metric calls are recorded, and drops the others, since a metric call, like a
    # log call, never raises.
    #
    # It is the one place that decides what is recordable: the Aggregator, so that it never raises or
    # corrupts a series, asks it too (see .recordable_value?), without warning. It drops a metric whose:
    # - name is not a String or Symbol, or is empty,
    # - value is not a real Numeric, or is not finite as a Float (NaN, Infinite, or too large, such as
    #   10**400), except the Integer amount of a counter, which is added exactly, however large,
    # - value is negative, for a counter, whose sum only ever grows,
    # - dimensions are neither nil nor a Hash.
    #
    # It also reports a metric call that failed as it was recorded (see #report_failure), such as one
    # with a dimension value that has no #hash.
    #
    # It warns once for each metric name and problem (a Symbol name and the same String are one name),
    # on the internal logger of the current processor (a stand-in for it in a test answers #logger too),
    # never through the deprecation framework. Once it has warned about WARNINGS_LIMIT of them, it drops
    # the rest without a warning, so that metric names built from values cannot use up the memory. In a
    # signal trap, where it cannot lock its Mutex, it drops them without a warning too.
    #
    # Asked by the Collector before it records a metric, and by SemanticLogger::Test::CaptureLogEvents
    # before it captures one, so that a test captures just what would be recorded.
    class Validator
      # Most warnings it makes, each for one metric name and problem.
      WARNINGS_LIMIT = 1000

      # Returns [true|false] whether `value` can be recorded as a metric of `kind`: a counter amount must
      # be an Integer, added exactly however large, or finite as a Float; a histogram value must be
      # finite as a Float, since its histogram records it as one. Real Numerics only. Never raises.
      #
      # kind: :counter or :histogram.
      def self.recordable_value?(kind, value)
        return true if kind == :counter && value.is_a?(Integer)
        return value.finite? if value.is_a?(Float)

        value.is_a?(Numeric) && value.real? && value.to_f.finite?
      rescue StandardError
        false
      end

      def initialize(warnings_limit: WARNINGS_LIMIT)
        @warnings_limit = warnings_limit
        @warned         = {}
        @lock           = Mutex.new
      end

      # Returns [String|nil] the name to record the metric as, a Symbol converted to a String, or nil when
      # the metric is dropped, after warning about it.
      #
      # kind: :counter or :histogram.
      def accept(kind, name, value, dimensions)
        problem =
          if !(name.is_a?(String) || name.is_a?(Symbol)) || name.empty?
            :name
          elsif !Validator.recordable_value?(kind, value)
            :value
          elsif kind == :counter && value.negative?
            :negative
          elsif !(dimensions.nil? || dimensions.is_a?(Hash))
            :dimensions
          end
        return name.is_a?(Symbol) ? name.name : name unless problem

        warn_once(problem, kind, name, value, dimensions)
        nil
      end

      # Reports, once for each metric name, that recording the metric raised `exception`, and returns
      # false, the result of the metric call. Never raises.
      def report_failure(kind, name, exception)
        warn_once(:failure, kind, name, exception, nil)
        false
      end

      # Reports, once for all metric names, that the collector failed as it recorded a metric, raising
      # `exception`, a defect of Semantic Logger rather than of the metric call. Returns false, the
      # result of the metric call. Never raises.
      def report_collector_failure(kind, name, exception)
        warn_once(:collector, kind, name, exception, nil)
        false
      end

      private

      # Builds the message before it marks the key as warned about, so that when building it raises,
      # such as an #inspect that raises, a later call can still warn. Builds it outside the lock, since
      # #inspect can be the application's.
      def warn_once(problem, kind, name, value, dimensions)
        key = [problem, warning_name(problem, name)]
        return unless warnable?(key)

        message = message(problem, kind, name, value, dimensions)
        first   = false
        TrapSafe.try_synchronize(@lock) do
          next unless unwarned?(key)

          @warned[key] = true
          first        = true
        end
        Logger.processor.logger.warn(message) if first
      rescue StandardError
        # Reporting it is best effort: a metric call never raises.
        nil
      end

      # Whether the key can still be warned about: false in a signal trap, where the lock cannot be held.
      def warnable?(key)
        warnable = false
        TrapSafe.try_synchronize(@lock) { warnable = unwarned?(key) }
        warnable
      end

      # Under the lock.
      def unwarned?(key) = !@warned.key?(key) && @warned.size < @warnings_limit

      # The name a warning is for. Any object can be given as the name: keep only its class. A Symbol is
      # the same name as its String, so that both are warned about once. A failure of the collector is
      # warned about once for every name.
      def warning_name(problem, name)
        return nil if problem == :collector
        return name.class if problem == :name || !(name.is_a?(String) || name.is_a?(Symbol))

        name.is_a?(Symbol) ? name.name : -name
      end

      def message(problem, kind, name, value, dimensions)
        dropped = "Dropped #{kind} #{Utils.safe_inspect(name)}"
        case problem
        when :name
          "#{dropped}: its name must be a non-empty String or Symbol. Further ones are dropped without a warning."
        when :value
          "#{dropped}: its value #{Utils.safe_inspect(value)} is not a real Numeric that is finite as a Float. " \
          "Further ones are dropped without a warning."
        when :failure
          "Failed to record #{kind} #{Utils.safe_inspect(name)}: " \
          "#{value.class}: #{Utils.safe_inspect(value.message)}. " \
          "Further failures are not reported."
        when :collector
          "Failed to record #{kind} #{Utils.safe_inspect(name)}, in the metrics collector: " \
          "#{value.class}: #{Utils.safe_inspect(value.message)}. " \
          "This is a defect of Semantic Logger: please report it. " \
          "Further failures of the collector are not reported."
        when :negative
          "#{dropped}: a counter cannot be decreased, its amount #{Utils.safe_inspect(value)} is negative. " \
          "Further ones are dropped without a warning."
        else
          "#{dropped}: its dimensions #{Utils.safe_inspect(dimensions)} are not a Hash. " \
          "Further ones are dropped without a warning."
        end
      end
    end
  end
end
