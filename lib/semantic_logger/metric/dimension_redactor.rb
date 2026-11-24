module SemanticLogger
  module Metric
    # Internal: answers, for each dimension key of a metric, the value that replaces a sensitive one, as the
    # Redactor of the sensitive keys does (see Redactor#replacement_for), except for the keys declared safe
    # (see SemanticLogger.safe_dimension_keys=), which are never replaced.
    #
    # The class knows the safe keys that are declared; each instance knows those of the moment it is made,
    # and the Redactor knows which keys are sensitive. The Collector makes one for each snapshot that it
    # redacts, so that safe keys declared since are used.
    class DimensionRedactor
      @safe_keys = [].freeze

      # Sets the dimension keys that are never redacted (see SemanticLogger.safe_dimension_keys=), each a
      # String or Symbol, kept as frozen Strings, once each.
      def self.safe_keys=(keys)
        keys = Array(keys).map do |key|
          next key.name if key.is_a?(Symbol)
          next key.dup if key.is_a?(String)

          raise(ArgumentError, "Expected each safe dimension key to be a String or Symbol, not #{key.inspect}")
        end
        @safe_keys = Utils.make_shareable(keys.uniq)
      end

      class << self
        # Returns [Array<String>] the dimension keys that are never redacted.
        attr_reader :safe_keys
      end

      # Parameters:
      #   redactor: [SemanticLogger::Redactor]
      #     The redactor of the sensitive keys.
      def initialize(redactor)
        @redactor  = redactor
        @safe_keys = self.class.safe_keys.to_h { |key| [key, true] }
      end

      # Returns the value that replaces the value of the dimension key, or nil when the key is safe, or not
      # sensitive. Raises what the Redactor raises.
      def replacement_for(key)
        return if @safe_keys.key?(key)

        @redactor.replacement_for(key)
      end
    end
  end
end
