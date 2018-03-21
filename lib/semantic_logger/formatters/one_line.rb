module SemanticLogger
  module Formatters
    # Only output one line for each log entry.
    #
    # Notes:
    # * New lines are stripped from log messages.
    # * Exceptions only include the class and message, the stack trace is not shown.
    class OneLine < Default
      def message
        "-- #{log.message.delete("\n")}" if log.message
      end

      def exception
        "-- Exception: #{log.exception.class}: #{log.exception.message.delete("\n")}" if log.exception
      end
    end
  end
end
