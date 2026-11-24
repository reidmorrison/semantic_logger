module SemanticLogger
  module Test
    # A metric call captured by SemanticLogger::Test::CaptureLogEvents, as it was made, before it is
    # aggregated: one for each `increment`, `time`, and `record` that would be recorded. Frozen.
    #
    #   kind:       :counter (increment) or :histogram (time and record).
    #   name:       [String] the name as it is recorded: frozen, a Symbol converted to a String (see
    #               Metric::Aggregator.metric_name).
    #   value:      [Numeric] the amount of a counter, or the value of a histogram: seconds for `time`.
    #   unit:       [String|nil] "s" for `time`, otherwise the unit given to `increment` or `record`.
    #   dimensions: [Hash|nil] the dimensions given, as they are recorded: a frozen copy with String keys,
    #               and Symbol values as Strings (see Metric::Aggregator.normalize_dimensions). nil when
    #               none were given, or an empty Hash, which the recorder treats as none too.
    MetricEvent = Data.define(:kind, :name, :value, :unit, :dimensions) do
      # Returns [Hash|nil] the dimensions as they are recorded: nil for none, an empty Hash included.
      def self.recorded_dimensions(dimensions)
        dimensions.nil? || dimensions.empty? ? nil : Metric::Aggregator.normalize_dimensions(dimensions)
      end

      def initialize(kind:, name:, value:, unit: nil, dimensions: nil)
        name       = Metric::Aggregator.metric_name(name) if name.is_a?(String) || name.is_a?(Symbol)
        dimensions = MetricEvent.recorded_dimensions(dimensions)
        super
      end

      # Returns [true|false] whether it has every attribute given. An expected value matches when it is:
      #   :nil       - and the attribute is nil,
      #   a Class    - and the attribute is a kind of it,
      #   a Range, a Regexp, or a Proc - and it matches the attribute (with ===),
      #   any other value - equal to the attribute.
      #
      # A Symbol name matches the same String. Expected dimensions given as a Hash are normalized as the
      # captured ones are, so that `dimensions: {plan: "free"}` matches the dimensions {plan: "free"} and
      # {"plan" => "free"}, recorded as one series, and `dimensions: {}` matches none, as `:nil` does.
      #
      # Raises ArgumentError when given an attribute it does not have.
      def matches?(kind: nil, name: nil, value: nil, unit: nil, dimensions: nil)
        name       = name.name if name.is_a?(Symbol) && name != :nil
        dimensions = MetricEvent.recorded_dimensions(dimensions) || :nil if dimensions.is_a?(Hash)
        expected   = {kind: kind, name: name, value: value, unit: unit, dimensions: dimensions}
        expected.all? do |attribute, expected_value|
          actual = public_send(attribute)
          case expected_value
          when nil
            true
          when :nil
            actual.nil?
          else
            expected_value === actual # rubocop:disable Style/CaseEquality
          end
        end
      end
    end
  end
end
