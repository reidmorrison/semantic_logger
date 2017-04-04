begin
  require 'syslog_protocol'
rescue LoadError
  raise 'Gem syslog_protocol is required for remote logging using the Syslog protol. Please add the gem "syslog_protocol" to your Gemfile.'
end

module SemanticLogger
  module Formatters
    class Syslog < Default
      attr_accessor :level_map, :options, :facility

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
      #   options: [Integer]
      #     Default: ::Syslog::LOG_PID | ::Syslog::LOG_CONS
      #     Any of the following (options can be logically OR'd together)
      #       ::Syslog::LOG_CONS
      #       ::Syslog::LOG_NDELAY
      #       ::Syslog::LOG_NOWAIT
      #       ::Syslog::LOG_ODELAY
      #       ::Syslog::LOG_PERROR
      #       ::Syslog::LOG_PID
      #
      #   facility: [Integer]
      #     Default: ::Syslog::LOG_USER
      #     Type of program (can be logically OR'd together)
      #       ::Syslog::LOG_AUTH
      #       ::Syslog::LOG_AUTHPRIV
      #       ::Syslog::LOG_CONSOLE
      #       ::Syslog::LOG_CRON
      #       ::Syslog::LOG_DAEMON
      #       ::Syslog::LOG_FTP
      #       ::Syslog::LOG_KERN
      #       ::Syslog::LOG_LRP
      #       ::Syslog::LOG_MAIL
      #       ::Syslog::LOG_NEWS
      #       ::Syslog::LOG_NTP
      #       ::Syslog::LOG_SECURITY
      #       ::Syslog::LOG_SYSLOG
      #       ::Syslog::LOG_USER
      #       ::Syslog::LOG_UUCP
      #       ::Syslog::LOG_LOCAL0
      #       ::Syslog::LOG_LOCAL1
      #       ::Syslog::LOG_LOCAL2
      #       ::Syslog::LOG_LOCAL3
      #       ::Syslog::LOG_LOCAL4
      #       ::Syslog::LOG_LOCAL5
      #       ::Syslog::LOG_LOCAL6
      #       ::Syslog::LOG_LOCAL7
      #
      #   level_map: [Hash | SemanticLogger::Formatters::Syslog::LevelMap]
      #     Supply a custom map of SemanticLogger levels to syslog levels.
      #
      #   Example:
      #     # Change the warn level to LOG_NOTICE level instead of a the default of LOG_WARNING.
      #     SemanticLogger.add_appender(appender: :syslog, level_map: {warn: ::Syslog::LOG_NOTICE})
      def initialize(options: ::Syslog::LOG_PID|::Syslog::LOG_CONS, facility: ::Syslog::LOG_USER, level_map: LevelMap.new)
        @options   = options
        @facility  = facility
        @level_map = level_map.is_a?(LevelMap) ? level_map : LevelMap.new(level_map)
        super
      end

      def call(log, logger)
        message = super(log, logger)
        create_syslog_packet(log, message)
      end

      # Create Syslog Packet
      def create_syslog_packet(log, message)
        packet          = SyslogProtocol::Packet.new
        packet.hostname = host
        packet.facility = facility
        packet.tag      = application.gsub(' ', '')
        packet.content  = message
        packet.time     = log.time
        packet.severity = level_map[log.level]
        packet.to_s
      end

      # time is part of the packet and is not included in the formatted message
      def time
        nil
      end

    end
  end
end

