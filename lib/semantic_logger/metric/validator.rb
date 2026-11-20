module SemanticLogger
  module Metric
    # Internal: knows which metric calls are recorded, and drops the others, since a metric call, like a
    # log call, never raises.
    #
    # It drops a metric whose:
    # - name is not a String or Symbol, or is empty,
    # - value is not a real Numeric, or is NaN or Infinite,
    # - value is negative, for a counter, whose sum only ever grows,
    # - dimensions are neither nil nor a Hash.
    #
    # It warns once for each metric name and problem, on the internal logger of the current processor
    # (see Processor.logger), never through the deprecation framework. Once it has warned about
    # WARNINGS_LIMIT of them, it drops the rest without a warning, so that metric names built from
    # values cannot use up the memory. In a signal trap, where it cannot lock its Mutex, it drops them
    # without a warning too.
    #
    # Asked by the Collector before it records a metric, and by SemanticLogger::Test::CaptureLogEvents
    # before it captures one, so that a test captures just what would be recorded.
    class Validator
      # Most warnings it makes, each for one metric name and problem.
      WARNINGS_LIMIT = 1000

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
          elsif !value.is_a?(Numeric) || !value.real? || !value.finite?
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

      private

      def warn_once(problem, kind, name, value, dimensions)
        # Any object can be given as the name: keep only its class.
        key   = [problem, problem == :name ? name.class : name]
        first = false
        TrapSafe.try_synchronize(@lock) do
          next if @warned.key?(key) || @warned.size >= @warnings_limit

          @warned[key] = true
          first        = true
        end
        return unless first

        Logger.processor.logger.warn(message(problem, kind, name, value, dimensions))
      rescue StandardError
        # Reporting it is best effort: a metric call never raises.
        nil
      end

      def message(problem, kind, name, value, dimensions)
        dropped = "Dropped #{kind} #{Utils.safe_inspect(name)}"
        case problem
        when :name
          "#{dropped}: its name must be a non-empty String or Symbol. Further ones are dropped without a warning."
        when :value
          "#{dropped}: its value #{Utils.safe_inspect(value)} is not a finite real Numeric. " \
          "Further ones are dropped without a warning."
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
