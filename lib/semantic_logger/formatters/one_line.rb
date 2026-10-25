module SemanticLogger
  module Formatters
    # Only output one line for each log entry.
    #
    # Notes:
    # * New lines and carriage returns are stripped from log messages.
    #   With `escape_control_chars: true` they, and all other control characters, are escaped
    #   instead, like the other text formatters.
    # * Exceptions only include the class and message, the stack trace is not shown.
    # * Exception details, when enabled, are joined onto the same line.
    class OneLine < Default
      def message
        "-- #{one_line(log.message)}" if log.message
      end

      def exception
        return unless log.exception

        details = exception_details
        "-- Exception: #{log.exception.class}: #{one_line(log.exception.message)}#{" -- #{details}" if details}"
      end

      # The exception details, with each line trimmed and joined by a space.
      def exception_details
        details = exception_details_for(log.exception) if log.exception
        one_line(details.split(/\s*\n\s*/).reject(&:empty?).join(" ").strip) if details
      end

      private

      # Off by default, so that existing one line output does not change.
      def default_log_exception_details
        false
      end

      # Returns [String] the value without line breaks, so that the entry stays on one line.
      def one_line(value)
        escape_control_characters(value.to_s).delete("\r\n")
      end
    end
  end
end
