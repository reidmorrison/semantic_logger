require "time"
module SemanticLogger
  module Formatters
    class Base
      attr_accessor :log, :logger, :time_format, :log_host, :log_application, :log_environment, :precision,
                    :escape_control_chars, :log_exception_details

      # Printable escapes for the most common control characters. Any other
      # control character is escaped to its hexadecimal `\xHH` form by
      # #escape_control_characters.
      CONTROL_CHAR_ESCAPES = {
        "\n" => "\\n",
        "\r" => "\\r",
        "\t" => "\\t",
        "\e" => "\\e"
      }.freeze

      # Matches C0 control characters (including newlines and the ANSI escape) and DEL.
      CONTROL_CHARS = /[\x00-\x1f\x7f]/

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
      #     Replace control characters (newlines, the ANSI escape, etc.) in
      #     untrusted log data (logger name, thread name, message, payload, tags,
      #     named tags, and the message and backtrace lines of the exception and
      #     of each exception that caused it) with a printable escaped form, e.g. "\n".
      #     This prevents log forging and terminal escape-sequence injection
      #     when logging data that may contain attacker-controlled content.
      #     Note: Has no effect on structured formatters such as :json, which
      #     already escape control characters via JSON encoding.
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
      def initialize(time_format: nil,
                     log_host: true,
                     log_application: true,
                     log_environment: true,
                     precision: PRECISION,
                     escape_control_chars: false,
                     log_exception_details: default_log_exception_details)
        @time_format          = time_format || self.class.build_time_format(precision)
        @log_host             = log_host
        @log_application      = log_application
        @log_environment      = log_environment
        @precision            = precision
        @escape_control_chars  = escape_control_chars
        @log_exception_details = log_exception_details
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
      # escape sequences. Otherwise the value is returned unchanged.
      #
      # Note: This escapes (preserves) control characters, and is opt-in. It is
      # distinct from Log#cleansed_message, which unconditionally *strips* ANSI
      # colorization from the message for structured (JSON/Loki) output.
      #
      # A string with invalid byte sequences, for example an exception message that quotes
      # untrusted binary input, or in another encoding, is first converted to valid UTF-8
      # (dropping the invalid bytes), since matching against it would raise and the log entry
      # would be lost.
      def escape_control_characters(value)
        return value unless escape_control_chars && value

        string = Utils.encode_utf8_string(value.to_s)
        string.gsub(CONTROL_CHARS) { |char| CONTROL_CHAR_ESCAPES[char] || format("\\x%02x", char.ord) }
      end

      # Whether this formatter logs exception details unless told otherwise. See #initialize.
      def default_log_exception_details
        false
      end

      # Returns [String] the detail Ruby adds to the message of the supplied exception (see
      # Log#exception_details), or nil when there is none or this formatter does not log it.
      def exception_details_for(exception)
        return unless log_exception_details

        log.exception_details(exception, source: log_exception_details == :with_source)
      end

      # Returns [String] the backtrace of the logged exception, followed by each exception
      # that caused it, as laid out by Log#backtrace_to_s.
      #
      # When `escape_control_chars` is enabled, the message of each cause and each backtrace
      # line is passed through #escape_control_characters, the same as the message of the
      # logged exception: causes are often parser or validation errors that quote untrusted
      # input, and a backtrace can be set from untrusted data.
      def exception_backtrace
        return log.backtrace_to_s unless escape_control_chars

        log.backtrace_to_s { |text| escape_control_characters(text) }
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
