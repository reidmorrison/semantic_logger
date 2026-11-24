module SemanticLogger
  module Metric
    # Internal: answers, for each dimension key of a metric, the value that replaces a sensitive one, as the
    # Redactor of the sensitive keys does (see Redactor#replacement_for), except for the keys declared safe
    # (see SemanticLogger.safe_dimension_keys=), which are never replaced.
    #
    # The class knows the safe keys that are declared; each instance knows those of the moment it is made,
    # and the Redactor knows which keys are sensitive. The Collector makes one for each snapshot that it
    # redacts, and a log entry one as it is redacted, so that safe keys declared since are used.
    class DimensionRedactor
      # The dimension keys that are always safe: "error.type", the attribute of the OpenTelemetry semantic
      # conventions that names the class of the error that failed an operation.
      DEFAULT_SAFE_KEYS = [-"error.type"].freeze

      # Returns [Hash] each safe key, true, to look them up.
      def self.lookup(keys) = Utils.make_shareable(keys.to_h { |key| [key, true] }.freeze)
      private_class_method :lookup

      @safe_keys   = DEFAULT_SAFE_KEYS
      @safe_lookup = lookup(DEFAULT_SAFE_KEYS)

      # Sets the dimension keys that are never redacted (see SemanticLogger.safe_dimension_keys=), each a
      # String or Symbol, kept as frozen Strings, once each, with DEFAULT_SAFE_KEYS.
      def self.safe_keys=(keys)
        keys = Array(keys).map do |key|
          next -key.name if key.is_a?(Symbol)
          next -key if key.is_a?(String)

          raise(ArgumentError, "Expected each safe dimension key to be a String or Symbol, not #{key.inspect}")
        end
        keys         = Utils.make_shareable((DEFAULT_SAFE_KEYS + keys).uniq.freeze)
        @safe_lookup = lookup(keys)
        @safe_keys   = keys
      end

      class << self
        # Returns [Array<String>] the dimension keys that are never redacted.
        attr_reader :safe_keys

        # Returns [Hash] each safe key, true, made once as the keys are set.
        attr_reader :safe_lookup
      end

      # Parameters:
      #   redactor: [SemanticLogger::Redactor]
      #     The redactor of the sensitive keys.
      def initialize(redactor)
        @redactor = redactor
        @safe     = self.class.safe_lookup
      end

      # Returns the value that replaces the value of the dimension key, or nil when the key is safe, or not
      # sensitive. Raises what the Redactor raises.
      def replacement_for(key)
        return if safe?(key)

        @redactor.replacement_for(key)
      end

      # Returns [Hash|nil] the dimensions of a log entry, redacted as the Redactor redacts a Hash (see
      # Redactor#redact), except that the value of a safe key, given as a String or Symbol, is not replaced
      # for its key, as a metric's is not; a structure that it holds is still redacted. Keeps the order of
      # the keys, and returns the dimensions themselves when nothing is redacted. When the Redactor cannot
      # redact them, returns what it returns instead, never a value it did not redact.
      def redact(dimensions)
        safe_key = dimensions.is_a?(Hash) && dimensions.each_key.any? { |key| safe?(key) }
        return @redactor.redact(dimensions) unless safe_key

        other    = dimensions.reject { |key, _value| safe?(key) }
        redacted = @redactor.redact(other)
        # The Redactor failed, and returned what says so instead.
        return redacted unless redacted.is_a?(Hash) && redacted.size == other.size

        merge_redacted(dimensions, redacted.each_pair.to_a, redacted.equal?(other))
      end

      private

      # Returns [Hash] the dimensions, each safe value redacted, and each other pair replaced, in turn, by
      # the pair that the Redactor returned for it, whose key it may have redacted too, such as a Hash key;
      # or the dimensions themselves when nothing changed.
      def merge_redacted(dimensions, pairs, unchanged)
        index  = -1
        result = dimensions.to_h do |key, value|
          next [key, @redactor.redact(value)] if safe?(key)

          pairs[index += 1]
        end
        unchanged && result.each_pair.all? { |key, value| value.equal?(dimensions[key]) } ? dimensions : result
      end

      def safe?(key)
        @safe.key?(key.is_a?(Symbol) ? key.name : key)
      end
    end
  end
end
