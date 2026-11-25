module SemanticLogger
  module Otlp
    # Writes Ruby values as the values of an OTLP message, in the Hash of its JSON encoding (see
    # Protobuf): text, a time, and an attribute's AnyValue, of any structure.
    module Values
      # The range of an int64 or sfixed64: an Integer outside it is not an intValue or asInt.
      INT64_RANGE = (-(2**63)..((2**63) - 1))

      NANOSECONDS = 1_000_000_000

      # Most structures, a Hash or an Array, nested in one another in an AnyValue. In the JSON encoding
      # each one is four levels deep (the AnyValue, the kvlistValue, its values, and each KeyValue), so
      # that a deeper one would pass JSON's limit of 100 levels, with the levels of the request around it.
      MAX_DEPTH = 20

      # Returns [Array<Hash>] a KeyValue for each key and value of the Hash, each value an AnyValue of
      # any structure (see .any_value).
      def self.attributes(hash)
        hash.map { |key, value| {key: text(key), value: any_value(value)} }
      end

      # Returns [Hash] the AnyValue of the value: a Hash as a kvlistValue and an Array as an arrayValue,
      # an Integer beyond 64 bits as its text, and nil as an empty AnyValue. Any other object is written
      # as its text. A structure is first made safe by Utils.json_safe, which ends one that holds
      # itself, and writes a Struct, Data, or Set as a Hash or an Array, never through its #inspect. A
      # structure nested deeper than MAX_DEPTH is written as a placeholder, such as
      # "#<Hash nested too deeply>", as Utils.json_safe writes one.
      def self.any_value(value)
        value = Utils.json_safe(value) if Utils.structure?(value)
        safe_any_value(value)
      end

      # Returns [String] the text of a String, Symbol, or other object, in valid UTF-8.
      def self.text(value)
        value = value.is_a?(Symbol) ? value.name : value.to_s
        Utils.encode_utf8_string(value)
      end

      # Returns [Float|String] the Float, or how the Protobuf JSON mapping writes one that is not
      # finite, which JSON cannot hold as a number.
      def self.double(value)
        if value.finite? then value
        elsif value.nan? then "NaN"
        elsif value.positive? then "Infinity"
        else
          "-Infinity"
        end
      end

      # Returns [String] decimal nanoseconds since the epoch of a Time, or of a Numeric in seconds.
      def self.nanoseconds(time)
        (time.to_r * NANOSECONDS).to_i.to_s
      end

      # The AnyValue of a value that Utils.json_safe returned, or of a scalar.
      def self.safe_any_value(value, depth = 0)
        if (value.is_a?(Hash) || value.is_a?(Array)) && depth >= MAX_DEPTH
          return {stringValue: "#<#{value.class} nested too deeply>"}
        end

        case value
        when true, false
          {boolValue: value}
        when Integer
          INT64_RANGE.cover?(value) ? {intValue: value.to_s} : {stringValue: value.to_s}
        when Float
          {doubleValue: double(value)}
        when nil
          {}
        when Hash
          {kvlistValue: {values: value.map { |key, item| {key: text(key), value: safe_any_value(item, depth + 1)} }}}
        when Array
          {arrayValue: {values: value.map { |item| safe_any_value(item, depth + 1) }}}
        else
          {stringValue: text(value)}
        end
      end
      private_class_method :safe_any_value
    end
  end
end
