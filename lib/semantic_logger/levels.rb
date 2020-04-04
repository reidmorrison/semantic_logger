module SemanticLogger
  module Levels
    # Logging levels in order of most detailed to most severe
    LEVELS = %i[trace debug info warn error fatal].freeze

    # Internal method to return the log level as an internal index
    # Also supports mapping the ::Logger levels to SemanticLogger levels
    def self.index(level)
      return if level.nil?

      index =
        if level.is_a?(Symbol)
          LEVELS.index(level)
        elsif level.is_a?(String)
          level = level.downcase.to_sym
          LEVELS.index(level)
        elsif level.is_a?(Integer) && defined?(::Logger::Severity)
          # Mapping of Rails and Ruby Logger levels to SemanticLogger levels
          @map_levels ||=
            begin
              levels = []
              ::Logger::Severity.constants.each do |constant|
                levels[::Logger::Severity.const_get(constant)] =
                  LEVELS.find_index(constant.downcase.to_sym) || LEVELS.find_index(:error)
              end
              levels
            end
          @map_levels[level]
        end
      raise "Invalid level:#{level.inspect} being requested. Must be one of #{LEVELS.inspect}" unless index

      index
    end

    # Returns the symbolic level for the supplied level index
    def self.level(level_index)
      LEVELS[level_index]
    end
  end
end
