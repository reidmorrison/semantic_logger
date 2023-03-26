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
        MAPPED_LEVELS[level]
      end ||
        raise(ArgumentError, "Invalid level:#{level.inspect} being requested. Must be one of #{LEVELS.inspect}")
    end

    # Returns the symbolic level for the supplied level index
    def self.level(level_index)
      LEVELS[level_index]
    end
  end
end
