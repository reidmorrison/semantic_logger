require "time"
module SemanticLogger
  module Formatters
    class Base
      attr_accessor :log, :logger, :log_host, :log_application, :log_environment, :precision,
                    :escape_control_chars, :log_exception_details

      # Printable escapes for the most common control characters. Any other ASCII
      # control character is escaped to its hexadecimal `\xHH` form by
      # #escape_control_characters, and a Unicode one (see UNICODE_CONTROL_CHARS)
      # to its `\uXXXX` form.
      CONTROL_CHAR_ESCAPES = Utils.make_shareable(
        {
          "\n" => "\\n",
          "\r" => "\\r",
          "\t" => "\\t",
          "\e" => "\\e"
        }.freeze
      )

      # Matches C0 control characters (including newlines and the ANSI escape) and DEL.
      CONTROL_CHARS = /[\x00-\x1f\x7f]/

      # Matches the characters of CONTROL_CHARS, and the Unicode characters that control how text
      # is shown: the C1 control characters (U+0080 to U+009F, including the next line U+0085),
      # which some terminals act on, the line and paragraph separators (U+2028, U+2029), at which
      # editors, browsers, and some log viewers start a new line, and the bidirectional controls
      # (U+202A to U+202E, U+2066 to U+2069), which can make logged text read in a different order
      # than it was written. Escaped in the `\uXXXX` form.
      UNICODE_CONTROL_CHARS = /[\x00-\x1f\x7f\u0080-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/

      # Time precision varies by Ruby interpreter
      # JRuby 9.1.8.0 supports microseconds
      PRECISION =
        if defined?(JRuby)
          if JRUBY_VERSION.to_f >= 9.1
            maint = JRUBY_VERSION.match(/\A\d+\.\d+\.(\d+)\./)[1].to_i
            (maint >= 8) || (JRUBY_VERSION.to_f > 9.1) ? 6 : 3
          else
            3
          end
        else
          6
        end

      # Parameters
      #   time_format: [String|Symbol|nil]
      #     See Time#strftime for the format of this string.
      #     :iso_8601 Outputs an ISO8601 Formatted timestamp.
      #     :ms       Output in miliseconds since epoch.
      #     :notime   Returns an empty string for time ( no time is output ).
      #     Default: '%Y-%m-%d %H:%M:%S.%<precision>N'
      #   log_host: [Boolean]
      #     Whether or not to include hostname in logs
      #     Default: true
      #   log_application: [Boolean]
      #     Whether or not to include application name in logs
      #     Default: true
      #   precision: [Integer]
      #     How many fractional digits to log times with.
      #     Default: PRECISION (6, except on older JRuby, where 3)
      #   escape_control_chars: [Boolean]
      #     Replace control characters (newlines, the ANSI escape, etc., and the Unicode
      #     characters that control how text is shown, such as U+2028 and U+202E) in
      #     untrusted log data (logger name, thread name, message, payload, tags,
      #     named tags, and the message and backtrace lines of the exception and
      #     of each exception that caused it) with a printable escaped form, e.g. "\n".
      #     This prevents log forging and terminal escape-sequence injection
      #     when logging data that may contain attacker-controlled content.
      #     Note: Has no effect on structured formatters such as :json, which
      #     already escape control characters via JSON encoding, except that
      #     :loki and :open_telemetry, which write the exception's stack trace
      #     as text, escape its backtrace lines and the messages of its causes.
      #     Default: false (preserve newlines and ANSI colors in text output)
      #   log_exception_details: [true|false|:with_source]
      #     Whether to log the detail that Ruby's Exception#detailed_message adds to an
      #     exception's message, such as did_you_mean suggestions ("Did you mean?  upcase") or
      #     the detail an exception class supplies by overriding #detailed_message.
      #     :with_source also logs error_highlight's snippet of the failing source line. It is
      #     about 100 times slower, since it re-parses that source file, and it copies source
      #     code into the log.
      #     On Ruby 3.2 a NameError or NoMethodError builds its message from receiver.inspect each
      #     time it is asked, and logging the details asks for it twice more, so turn this off when
      #     inspecting the receivers of logged exceptions is slow.
      #     Default: true for the Default, Color, and Pattern text formatters, false otherwise.
      #   backtrace_cleaner: [true|false|Object]
      #     Cleans the backtrace of the logged exception, and of each exception that caused it,
      #     before it is written, leaving out or shortening lines. Only this formatter's output
      #     changes: the exceptions are not.
      #     true:  Use the application's cleaner, SemanticLogger.backtrace_cleaner, when one is set.
      #     false: Write the full backtrace.
      #     Or a cleaner of this formatter's own, which responds to `#clean` or `#call` (see
      #     SemanticLogger.backtrace_cleaner=).
      #     Default: true for the text formatters (Default and those built on it) and the Json
      #     formatters, false otherwise.
      def initialize(time_format: nil,
                     log_host: true,
                     log_application: true,
                     log_environment: true,
                     precision: PRECISION,
                     escape_control_chars: false,
                     log_exception_details: default_log_exception_details,
                     backtrace_cleaner: default_backtrace_cleaner)
        self.time_format      = time_format || self.class.build_time_format(precision)
        @log_host             = log_host
        @log_application      = log_application
        @log_environment      = log_environment
        @precision            = precision
        @escape_control_chars  = escape_control_chars
        @log_exception_details = log_exception_details
        self.backtrace_cleaner = backtrace_cleaner
      end

      # Returns [String|Symbol] the `time_format` option. See #initialize.
      attr_reader :time_format

      # Sets the `time_format` option. See #initialize.
      #
      # A format String is converted once, here, as #joinable_text converts the formatter's own
      # text: a format with characters outside ASCII in another encoding, such as ISO-8859-1, could
      # not otherwise be joined with the entry's other text.
      def time_format=(time_format)
        @time_format = joinable_text(time_format)
      end

      # Returns [true|false|Object] the `backtrace_cleaner` option. See #initialize.
      attr_reader :backtrace_cleaner

      # Sets the `backtrace_cleaner` option. See #initialize.
      # Raises ArgumentError for any other value, so that a mistake surfaces here rather than on
      # every log entry.
      #
      # Compared by identity, since a cleaner, such as a test double, need not define #== or #nil?.
      def backtrace_cleaner=(cleaner)
        unless true.equal?(cleaner) || false.equal?(cleaner) || nil.equal?(cleaner)
          BacktraceCleaning.validate!(cleaner, expected: "true, false, or a backtrace cleaner")
        end

        @backtrace_cleaner = cleaner
      end

      # Return default time format string
      #
      # Parameters
      #   precision: [Integer]
      #     How many fractional digits to log times with.
      #     Default: PRECISION (6, except on older JRuby, where 3)
      def self.build_time_format(precision = PRECISION)
        "%Y-%m-%d %H:%M:%S.%#{precision}N"
      end

      # Date & time
      def time
        format_time(log.time) if time_format
      end

      # Process ID
      def pid
        $$
      end

      private

      # When `escape_control_chars` is enabled, return a copy of the supplied
      # value with any control characters replaced by a printable escaped form
      # so that untrusted log data cannot forge log entries or inject terminal
      # escape sequences.
      #
      # Note: This escapes (preserves) control characters, and is opt-in. It is
      # distinct from Log#cleansed_message, which unconditionally *strips* ANSI
      # colorization from the message for structured (JSON/Loki) output.
      #
      # A string with invalid byte sequences, for example an exception message that quotes
      # untrusted binary input, or in another encoding, is first converted to valid UTF-8
      # (dropping the invalid bytes), since matching against it would raise and the log entry
      # would be lost.
      #
      # Otherwise the value is returned unchanged, unless it is a String that cannot be joined with
      # UTF-8 text: one that holds bytes outside ASCII in another encoding, such as a binary
      # response body or ISO-8859-1 text, or that is not ASCII-compatible, such as UTF-16. Joining
      # it with the entry's other text, such as an accented logger name, would raise and lose the
      # entry, so it is converted to valid UTF-8 (see Utils.encode_utf8_string), and this
      # formatter's output is UTF-8. A String tagged UTF-8 that holds invalid bytes joins with
      # UTF-8 text, so it is still written as it is.
      def escape_control_characters(value)
        unless escape_control_chars
          # As #joinable_text, written out here since every field of every entry passes through,
          # and almost every one is UTF-8 or ASCII.
          return value unless value.is_a?(String) && value.encoding != Encoding::UTF_8 && !value.ascii_only?

          return Utils.encode_utf8_string(value)
        end
        return value unless value

        string = Utils.encode_utf8_string(value.to_s)
        # Most text is ASCII, which only the ASCII control characters need to be looked for in.
        string.gsub(string.ascii_only? ? CONTROL_CHARS : UNICODE_CONTROL_CHARS) do |char|
          CONTROL_CHAR_ESCAPES[char] || format(char.ord < 0x80 ? "\\x%02x" : "\\u%04x", char.ord)
        end
      end

      # Returns the value as text that can be joined with this formatter's UTF-8 output: a String
      # that holds bytes outside ASCII in another encoding converted to UTF-8 (see
      # Utils.encode_utf8_string), and anything else as it is, including a UTF-8 String that holds
      # invalid bytes. For the formatter's own text, such as its time format, which is not escaped.
      # #escape_control_characters applies the same rule to the entry's fields.
      def joinable_text(value)
        return value unless value.is_a?(String) && value.encoding != Encoding::UTF_8 && !value.ascii_only?

        Utils.encode_utf8_string(value)
      end

      # Whether this formatter logs exception details unless told otherwise. See #initialize.
      def default_log_exception_details
        false
      end

      # Whether this formatter uses the application's backtrace cleaner unless told otherwise.
      # See #initialize.
      def default_backtrace_cleaner
        false
      end

      # Returns the backtrace cleaner to use for this log entry, or nil when backtraces are written
      # in full.
      #
      # The application's cleaner is looked up for each entry, rather than when this formatter is
      # built, so that it can be set after the appenders are added.
      def active_backtrace_cleaner
        cleaner = backtrace_cleaner
        return SemanticLogger.backtrace_cleaner if true.equal?(cleaner)

        cleaner || nil
      end

      # Returns [String] the detail Ruby adds to the message of the supplied exception (see
      # Log#exception_details), or nil when there is none or this formatter does not log it.
      def exception_details_for(exception)
        return unless log_exception_details

        log.exception_details(exception, source: log_exception_details == :with_source)
      end

      # Returns [String] the backtrace of the logged exception, followed by each exception
      # that caused it, as laid out by Log#backtrace_to_s, and cleaned by the backtrace cleaner
      # (see #initialize).
      #
      # When `escape_control_chars` is enabled, the message of each cause and each backtrace
      # line is passed through #escape_control_characters, the same as the message of the
      # logged exception: causes are often parser or validation errors that quote untrusted
      # input, and a backtrace can be set from untrusted data.
      #
      # Otherwise they are written as they are, unless the text cannot be joined with UTF-8 text,
      # such as when a cause's message is ISO-8859-1 text: then each is converted as
      # #escape_control_characters converts the other fields.
      def exception_backtrace
        cleaner = active_backtrace_cleaner
        unless escape_control_chars
          text = joinable_backtrace(cleaner)
          return text if text
        end

        log.backtrace_to_s(cleaner: cleaner) { |text| escape_control_characters(text) }
      end

      # Returns [String] the backtrace as Log#backtrace_to_s writes it, or nil when that text
      # cannot be joined with UTF-8 text (see #escape_control_characters).
      #
      # The text is checked once, rather than each of what is usually dozens of lines, which
      # would double the time it takes to format an exception.
      def joinable_backtrace(cleaner)
        text = log.backtrace_to_s(cleaner: cleaner)
        text if text.encoding == Encoding::UTF_8 || text.ascii_only?
      end

      # Return the Time as a formatted string
      def format_time(time)
        time = time.dup
        case time_format
        when :rfc_3339
          time.utc.to_datetime.rfc3339
        when :iso_8601
          time.utc.iso8601(precision)
        when :ms
          (time.to_f * 1_000).to_i
        when :none
          time
        when :seconds
          time.to_f
        when :notime
          ""
        else
          time.strftime(time_format)
        end
      end
    end
  end
end
