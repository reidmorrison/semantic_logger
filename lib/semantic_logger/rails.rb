#
# IGNORE THIS FILE
#

module SemanticLogger
  module Appender
    # Logger appender
    #
    #   Maps the SemanticLogger API's to the Rails log, or Ruby Logger
    #
    #   The following changes are made:
    #     The klass_name is prefixed on all log entries if available.
    #
    # Note: For performance, the original Rails Logger or Ruby Logger is returned,
    #       with that instance populated with the new API's to support SymanticLogger
    #
    # Installation:
    #    Rails.logger = SemanticLogger::LoggerAppender.new(Rails.logger)
    # Also works with the Ruby Logger
    #    logger = Logger.new ....
    #    Rails.log = LoggerAppender.new()
    #
    # ActiveResource::BufferedLogger
    #    ...
    #
    # Append to the default Rails log
    #
    # Note: The Rails log must be initialized prior to this Appender being started
    #       Or, the original Rails log must be passed into the initializer
    #
    class Logger
      @@level_map = {:trace => :debug, :debug=>:debug, :info=>:info, :warn=>:warn, :error=>:error}

      # These are a problem at the appender level, need to move to API
      # Not consistent with the other appenders levels
      def level
        @logger.level
      end

      def level=(new_level)
        @logger.level = new_level
      end



    end
  end
end