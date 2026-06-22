require "time"
module SemanticLogger
  module Formatters
    class Base
      attr_accessor :log, :logger, :time_format, :log_host, :log_application, :log_environment, :precision,
                    :escape_control_chars

      # Printable escapes for the most common control characters. Any other
      # control character is escaped to its hexadecimal `\xHH` form by #cleanse.
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
      #     untrusted log data (message, tags, named tags, and exception
      #     message) with a printable escaped form, e.g. "\n".
      #     This prevents log forging and terminal escape-sequence injection
      #     when logging data that may contain attacker-controlled content.
      #     Note: Has no effect on structured formatters such as :json, which
      #     already escape control characters via JSON encoding.
      #     Default: false (preserve newlines and ANSI colors in text output)
      def initialize(time_format: nil,
                     log_host: true,
                     log_application: true,
                     log_environment: true,
                     precision: PRECISION,
                     escape_control_chars: false)
        @time_format          = time_format || self.class.build_time_format(precision)
        @log_host             = log_host
        @log_application      = log_application
        @log_environment      = log_environment
        @precision            = precision
        @escape_control_chars = escape_control_chars
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
      def cleanse(value)
        return value unless escape_control_chars && value

        value.to_s.gsub(CONTROL_CHARS) { |char| CONTROL_CHAR_ESCAPES[char] || format("\\x%02x", char.ord) }
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
