module SemanticLogger
  module Formatters
    # Only output one line for each log entry.
    #
    # Notes:
    # * New lines and carriage returns are stripped from every text field: the name, thread name,
    #   tags, named tags, message, payload and exception message.
    #   With `escape_control_chars: true` they, and all other control characters, are escaped
    #   instead, like the other text formatters.
    # * Exceptions only include the class and message, the stack trace is not shown.
    # * Exception details, when enabled, are joined onto the same line.
    class OneLine < Default
      def thread_name
        format("%.30s", one_line(log.thread_name))
      end

      def tags
        return if log.tags.nil? || log.tags.empty?

        "[#{log.tags.map { |tag| one_line(tag) }.join('] [')}]"
      end

      def named_tags
        named_tags = log.named_tags
        return if named_tags.nil? || named_tags.empty?

        list = named_tags.map { |name, value| "#{one_line(name)}: #{one_line(value)}" }
        "{#{list.join(', ')}}"
      end

      def name
        one_line(log.name) if log.name
      end

      def message
        "-- #{one_line(log.message)}" if log.message
      end

      def payload
        pl = log.payload_to_s
        "-- #{one_line(pl)}" if pl
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
