require "time"
module SemanticLogger
  module Formatters
    class Base
      attr_accessor :log, :logger, :time_format, :log_host, :log_application, :log_environment, :precision

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
      def initialize(time_format: nil,
                     log_host: true,
                     log_application: true,
                     log_environment: true,
                     precision: PRECISION)
        @time_format     = time_format || self.class.build_time_format(precision)
        @log_host        = log_host
        @log_application = log_application
        @log_environment = log_environment
        @precision       = precision
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
        when nil
          ""
        else
          time.strftime(time_format)
        end
      end
    end
  end
end
