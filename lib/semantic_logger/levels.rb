require "logger"

module SemanticLogger
  module Levels
    # Logging levels in order of most detailed to most severe
    LEVELS = %i[trace debug info warn error fatal].freeze

    # Map the built-in `Logger` levels to SemanticLogger levels.
    MAPPED_LEVELS =
      ::Logger::Severity.constants.each_with_object([]) do |constant, levels|
        logger_value = ::Logger::Severity.const_get(constant)
        levels[logger_value] = LEVELS.find_index(constant.downcase.to_sym) || LEVELS.find_index(:error)
      end.freeze

    # Internal method to return the log level as an internal index
    # Also supports mapping the ::Logger levels to SemanticLogger levels
    def self.index(level)
      return if level.nil?

      case level
      when Symbol
        LEVELS.index(level)
      when String
        LEVELS.index(level.downcase.to_sym)
      when Integer
        # Bounded first, since Array#[] raises RangeError for an Integer too large for a C long, and
        # counts a negative Integer from the end.
        MAPPED_LEVELS[level] if level >= 0 && level < MAPPED_LEVELS.size
      end || raise(ArgumentError, invalid_message(level))
    end

    # Returns the level as an internal index, as #index does, but raises ArgumentError for nil too,
    # for a level that must be given.
    def self.index!(level)
      index(level) || raise(ArgumentError, invalid_message(level))
    end

    def self.invalid_message(level)
      "Invalid level:#{level.inspect} being requested. Must be one of #{LEVELS.inspect}"
    end
    private_class_method :invalid_message

    # Returns [true|false] whether the supplied value is a level that #index accepts.
    # Never raises, so it can be used to check values that come from untrusted data.
    def self.valid?(level)
      !index(level).nil?
    rescue ArgumentError
      false
    end

    # Returns the symbolic level for the supplied level index
    def self.level(level_index)
      LEVELS[level_index]
    end
  end
end
