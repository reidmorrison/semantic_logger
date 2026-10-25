module SemanticLogger
  module Formatters
    # Only output one line for each log entry.
    #
    # Notes:
    # * New lines are stripped from log messages.
    # * Exceptions only include the class and message, the stack trace is not shown.
    # * Exception details, when enabled, are joined onto the same line.
    class OneLine < Default
      def message
        "-- #{log.message.delete("\n")}" if log.message
      end

      def exception
        return unless log.exception

        details = exception_details
        "-- Exception: #{log.exception.class}: #{log.exception.message.delete("\n")}#{" -- #{details}" if details}"
      end

      # The exception details, with each line trimmed and joined by a space.
      def exception_details
        details = exception_details_for(log.exception) if log.exception
        escape_control_characters(details.split(/\s*\n\s*/).reject(&:empty?).join(" ").strip) if details
      end

      private

      # Off by default, so that existing one line output does not change.
      def default_log_exception_details
        false
      end
    end
  end
end
