require 'time'
module SemanticLogger
  module Formatters
    class Base
      attr_accessor :time_format, :log_host, :log_application

      # Time precision varies by Ruby interpreter
      # JRuby 9.1.8.0 supports microseconds
      PRECISION   =
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
      TIME_FORMAT = "%Y-%m-%d %H:%M:%S.%#{PRECISION}N".freeze

      # Parameters
      #   time_format: [String|Symbol|nil]
      #     See Time#strftime for the format of this string.
      #     :iso_8601 Outputs an ISO8601 Formatted timestamp.
      #     :ms       Output in miliseconds since epoch.
      #     nil:      Returns Empty string for time ( no time is output ).
      #     Default: '%Y-%m-%d %H:%M:%S.%6N'
      def initialize(time_format: TIME_FORMAT, log_host: true, log_application: true)
        @time_format     = time_format
        @log_host        = log_host
        @log_application = log_application
      end

      # Date & time
      def time
        format_time(log.time) if time_format
      end

      private

      # Return the Time as a formatted string
      def format_time(time)
        case time_format
        when :rfc_3339
          time.utc.to_datetime.rfc3339
        when :iso_8601
          time.utc.iso8601(PRECISION)
        when :ms
          (time.to_f * 1_000).to_i
        when :none
          time
        when :seconds
          time.to_f
        when nil
          ''
        else
          time.strftime(time_format)
        end
      end
    end
  end
end
