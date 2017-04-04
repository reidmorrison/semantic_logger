module SemanticLogger
  module Formatters
    class Base
      attr_accessor :time_format, :log_host, :log_application

      # Time precision varies by Ruby interpreter
      PRECISION   = defined?(JRuby) ? 3 : 6
      TIME_FORMAT = "%Y-%m-%d %H:%M:%S.%#{PRECISION}N"

      # Parameters
      #   time_format: [String|Symbol|nil]
      #     See Time#strftime for the format of this string
      #     :iso_8601 Outputs an ISO8601 Formatted timestamp
      #     nil:      Returns Empty string for time ( no time is output ).
      #     Default: '%Y-%m-%d %H:%M:%S.%6N'
      def initialize(time_format: TIME_FORMAT, log_host: true, log_application: true)
        @time_format     = time_format
        @log_host        = log_host
        @log_application = log_application
      end

      # Return the Time as a formatted string
      def format_time(time)
        case time_format
        when :iso_8601
          time.utc.iso8601(PRECISION)
        when nil
          ''
        else
          time.strftime(time_format)
        end
      end

    end
  end
end
