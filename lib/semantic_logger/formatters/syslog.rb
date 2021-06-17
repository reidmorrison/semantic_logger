begin
  require "syslog_protocol"
rescue LoadError
  raise LoadError,
        'Gem syslog_protocol is required for remote logging using the Syslog protocol. Please add the gem "syslog_protocol" to your Gemfile.'
end

module SemanticLogger
  module Formatters
    class Syslog < Default
      attr_accessor :level_map, :facility, :max_size

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

        def initialize(trace: ::Syslog::LOG_DEBUG, debug: ::Syslog::LOG_INFO, info: ::Syslog::LOG_NOTICE, warn: ::Syslog::LOG_WARNING, error: ::Syslog::LOG_ERR, fatal: ::Syslog::LOG_CRIT)
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
      #     Default: ::Syslog::LOG_USER
      #
      #   level_map: [Hash | SemanticLogger::Formatters::Syslog::LevelMap]
      #     Supply a custom map of SemanticLogger levels to syslog levels.
      #
      #   Example:
      #     # Change the warn level to LOG_NOTICE level instead of a the default of LOG_WARNING.
      #     SemanticLogger.add_appender(appender: :syslog, level_map: {warn: ::Syslog::LOG_NOTICE})
      def initialize(facility: ::Syslog::LOG_USER, level_map: LevelMap.new, max_size: Integer)
        @facility  = facility
        @level_map = level_map.is_a?(LevelMap) ? level_map : LevelMap.new(level_map)
        @max_size = max_size
        super()
      end

      # Time is part of the syslog packet and is not included in the formatted message.
      def time
        nil
      end

      def call(log, logger)
        message = super(log, logger)
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
