module SemanticLogger
  module Formatters
    # Only output one line for each log entry.
    #
    # Notes:
    # * Line breaks are stripped from every text field: the name, thread name, file name, tags,
    #   named tags, message, payload and exception message. They are new lines, carriage returns,
    #   vertical tabs and form feeds (which most terminals move down a line for), and the Unicode
    #   next line (U+0085), line separator (U+2028), and paragraph
    #   separator (U+2029), at which editors, browsers, and some log viewers also start a new line.
    #   With `escape_control_chars: true` they are escaped instead, the Unicode ones in the
    #   `\uXXXX` form, and so are the other control characters, as the other text formatters
    #   escape them: the ASCII ones, and the Unicode ones that control how text is shown, such as
    #   the bidirectional controls (see Base::UNICODE_CONTROL_CHARS).
    # * Exceptions only include the class and message, the stack trace is not shown.
    # * Exception details, when enabled, are joined onto the same line.
    class OneLine < Default
      # The line breaks that Unicode adds to the line feed and carriage return: next line, line
      # separator, and paragraph separator.
      UNICODE_LINE_BREAKS = "\u0085\u2028\u2029".freeze

      # The ASCII line breaks: line feed, carriage return, vertical tab, and form feed, at which most
      # terminals move down a line, as a String#delete character set.
      ASCII_LINE_BREAKS = "\r\n\v\f".freeze

      # Every line break, as a String#delete character set.
      LINE_BREAKS = "#{ASCII_LINE_BREAKS}#{UNICODE_LINE_BREAKS}".freeze

      # A line break, with the white space around it, between two lines of exception details. A
      # carriage return before a line feed is part of that white space.
      DETAILS_LINE_BREAK = /\s*[\n#{UNICODE_LINE_BREAKS}]\s*/

      # Shortened before its line breaks are removed or escaped, as the other text formatters do
      # (see Default#shortened_thread_name), so that an escape is never cut in two.
      def thread_name
        one_line(shortened_thread_name)
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

      # A log call can supply the backtrace that the file name and method come from.
      def file_name_and_line
        file, line = log.file_name_and_line(true)
        return unless file

        label = method_name
        label ? "#{one_line(file)}:#{line} #{label}" : "#{one_line(file)}:#{line}"
      end

      def method_name
        label = log.call_site&.label
        one_line(label) if label
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

        message = one_line(Utils.exception_message(log.exception))
        details = exception_details
        "-- Exception: #{Utils.exception_name(log.exception)}: #{message}#{" -- #{details}" if details}"
      end

      # The exception details, with each line trimmed and joined by a space.
      def exception_details
        details = exception_details_for(log.exception) if log.exception
        return unless details

        one_line(Utils.encode_utf8_string(details).split(DETAILS_LINE_BREAK).reject(&:empty?).join(" ").strip)
      end

      private

      # Off by default, so that existing one line output does not change.
      def default_log_exception_details
        false
      end

      # Returns [String] the value without line breaks, so that the entry stays on one line.
      # With `escape_control_chars: true`, #escape_control_characters has already escaped them, the
      # Unicode ones as in "\u2028".
      #
      # A String with invalid bytes, such as a request parameter decoded from "%FF", or in another
      # encoding, such as a binary request body, is converted to valid UTF-8 first, since deleting
      # from it, or joining it with UTF-8 text, would raise and lose the entry.
      def one_line(value)
        text = Utils.encode_utf8_string(escape_control_characters(value.to_s))
        # #escape_control_characters has already escaped every line break.
        return text if escape_control_chars
        # Most text is ASCII, which only the ASCII line breaks need to be deleted from.
        return text.delete(ASCII_LINE_BREAKS) if text.ascii_only?

        text.delete(LINE_BREAKS)
      end
    end
  end
end
