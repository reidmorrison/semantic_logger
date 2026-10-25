module SemanticLogger
  module Formatters
    class Syslog < Default
      attr_accessor :level_map, :facility, :max_size

      # Syslog severities and the default facility, with the same values as the matching
      # `::Syslog` constants. The `syslog` gem is only needed to log to a local syslog daemon, and
      # since Ruby 3.4 it is a bundled gem, so remote syslog must not depend on it for these values.
      LOG_CRIT    = 2
      LOG_ERR     = 3
      LOG_WARNING = 4
      LOG_NOTICE  = 5
      LOG_INFO    = 6
      LOG_DEBUG   = 7
      LOG_USER    = 1 << 3

      # Default level map for every log level
      #
      # :fatal   => ::Syslog::LOG_CRIT    - "A critical condition has occurred"
      # :error   => ::Syslog::LOG_ERR     - "An error occurred"
      # :warning =>::Syslog::LOG_WARNING  - "Warning of a possible problem"
      # :info    => ::Syslog::LOG_NOTICE  - "A normal but significant condition occurred"
      # :debug   => ::Syslog::LOG_INFO    - "Informational message"
      # :trace   => ::Syslog::LOG_DEBUG   - "Debugging information"
      #
      # The following levels are not used by default.
      # ::Syslog::LOG_EMERG   - "System is unusable"
      # ::Syslog::LOG_ALERT   - "Action needs to be taken immediately"
      class LevelMap
        attr_accessor :trace, :debug, :info, :warn, :error, :fatal

        def initialize(trace: LOG_DEBUG, debug: LOG_INFO, info: LOG_NOTICE,
                       warn: LOG_WARNING, error: LOG_ERR, fatal: LOG_CRIT)
          @trace = trace
          @debug = debug
          @info  = info
          @warn  = warn
          @error = error
          @fatal = fatal
        end

        def [](level)
          public_send(level)
        end
      end

      # Create a Syslog Log Formatter
      #
      # Parameters:
      #   facility: [Integer]
      #     Default: LOG_USER
      #
      #   level_map: [Hash | SemanticLogger::Formatters::Syslog::LevelMap]
      #     Supply a custom map of SemanticLogger levels to syslog levels.
      #
      #   escape_control_chars: [Boolean]
      #     Replace control characters (newlines, the ANSI escape, etc.) in
      #     untrusted log data with a printable escaped form so that they cannot
      #     forge or split syslog records.
      #     Default: true (unlike other formatters, since syslog frames records
      #     with a separator)
      #
      #   Example:
      #     # Change the warn level to LOG_NOTICE level instead of a the default of LOG_WARNING.
      #     SemanticLogger.add_appender(appender: :syslog, level_map: {warn: ::Syslog::LOG_NOTICE})
      def initialize(facility: LOG_USER, level_map: LevelMap.new, max_size: Integer,
                     escape_control_chars: true, **args)
        begin
          require "syslog_protocol"
        rescue LoadError
          raise LoadError,
                "Gem syslog_protocol is required for remote logging using the Syslog protocol. " \
                'Please add the gem "syslog_protocol" to your Gemfile.'
        end

        @facility  = facility
        @level_map = level_map.is_a?(LevelMap) ? level_map : LevelMap.new(**level_map)
        @max_size = max_size
        # Syslog frames records with a separator, so embedded newlines or other
        # control characters in untrusted log data can forge or split records.
        # Default to escaping them, overridable for backwards compatibility.
        super(escape_control_chars: escape_control_chars, **args)
      end

      # Time is part of the syslog packet and is not included in the formatted message.
      def time
        nil
      end

      def call(log, logger)
        message = super
        create_syslog_packet(message)
      end

      private

      # Create Syslog Packet
      def create_syslog_packet(message)
        packet          = SyslogProtocol::Packet.new
        packet.hostname = logger.host
        packet.facility = facility
        packet.tag      = logger.application.delete(" ")
        packet.content  = message
        packet.time     = log.time
        packet.severity = level_map[log.level]
        packet.assemble(@max_size)
      end
    end
  end
end
