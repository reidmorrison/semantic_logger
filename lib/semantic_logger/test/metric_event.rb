module SemanticLogger
  module Test
    # A metric call captured by SemanticLogger::Test::CaptureLogEvents, as it was made, before it is
    # aggregated: one for each `increment`, `time`, and `record` that would be recorded. Frozen.
    #
    #   kind:       :counter (increment) or :histogram (time and record).
    #   name:       [String] the name, a Symbol converted to a String, as it is recorded.
    #   value:      [Numeric] the amount of a counter, or the value of a histogram: seconds for `time`.
    #   unit:       [String|nil] "s" for `time`, otherwise the unit given to `record`.
    #   dimensions: [Hash|nil] the dimensions given, a frozen copy.
    MetricEvent = Data.define(:kind, :name, :value, :unit, :dimensions) do
      def initialize(kind:, name:, value:, unit: nil, dimensions: nil)
        dimensions = dimensions.dup.freeze if dimensions && !dimensions.frozen?
        super
      end

      # Returns [true|false] whether it has every attribute given. An expected value matches when it is:
      #   :nil       - and the attribute is nil,
      #   a Class    - and the attribute is a kind of it,
      #   a Range, a Regexp, or a Proc - and it matches the attribute (with ===),
      #   any other value - equal to the attribute. A Symbol name matches the same String.
      #
      # Raises ArgumentError when given an attribute it does not have.
      def matches?(kind: nil, name: nil, value: nil, unit: nil, dimensions: nil)
        expected = {kind: kind, name: name.is_a?(Symbol) ? name.name : name, value: value, unit: unit,
                    dimensions: dimensions}
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
