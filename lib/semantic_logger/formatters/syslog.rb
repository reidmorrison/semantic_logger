module SemanticLogger
  module Formatters
    class Syslog < Default
      attr_accessor :max_size
      attr_reader :facility, :level_map

      # Syslog severities and facilities, with the same values as the matching `::Syslog` constants.
      # The `syslog` gem is only needed to log to a local syslog daemon, and since Ruby 3.4 it is a
      # bundled gem, so remote syslog must not depend on it for these values.
      LOG_CRIT    = 2
      LOG_ERR     = 3
      LOG_WARNING = 4
      LOG_NOTICE  = 5
      LOG_INFO    = 6
      LOG_DEBUG   = 7

      # Syslog facilities, as syslog(3) defines them: the facility number shifted left by 3 bits.
      LOG_KERN     = 0 << 3
      LOG_USER     = 1 << 3
      LOG_MAIL     = 2 << 3
      LOG_DAEMON   = 3 << 3
      LOG_AUTH     = 4 << 3
      LOG_SYSLOG   = 5 << 3
      LOG_LPR      = 6 << 3
      LOG_NEWS     = 7 << 3
      LOG_UUCP     = 8 << 3
      LOG_CRON     = 9 << 3
      LOG_AUTHPRIV = 10 << 3
      LOG_FTP      = 11 << 3
      LOG_LOCAL0   = 16 << 3
      LOG_LOCAL1   = 17 << 3
      LOG_LOCAL2   = 18 << 3
      LOG_LOCAL3   = 19 << 3
      LOG_LOCAL4   = 20 << 3
      LOG_LOCAL5   = 21 << 3
      LOG_LOCAL6   = 22 << 3
      LOG_LOCAL7   = 23 << 3

      # Default maximum size of a syslog packet, in bytes, as for the syslog appender.
      DEFAULT_MAX_SIZE = 1024

      # The highest facility the syslog protocol can encode.
      MAX_FACILITY = LOG_LOCAL7

      # Returns [Integer] the facility number (0 to 23) that the syslog protocol sends, for a facility
      # given as documented: one of the `::Syslog::LOG_*` facility constants, such as
      # `::Syslog::LOG_LOCAL0`. syslog(3) defines each of those as the facility number shifted left
      # by 3 bits, so `::Syslog::LOG_USER` is 8 and its facility number is 1.
      #
      # Raises ArgumentError for any other value, including a bare facility number.
      def self.facility_number(facility)
        unless facility.is_a?(Integer) && (facility % 8).zero? && facility.between?(0, MAX_FACILITY)
          raise(ArgumentError,
                "Invalid syslog facility: #{facility.inspect}. Must be one of the ::Syslog::LOG_* facility " \
                "constants, for example ::Syslog::LOG_USER or ::Syslog::LOG_LOCAL0.")
        end

        facility >> 3
      end

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

        # Returns [LevelMap] the supplied level map, or a new one with a Hash of overrides applied,
        # for example `{warn: LOG_NOTICE}`.
        def self.build(level_map)
          level_map.is_a?(LevelMap) ? level_map : new(**level_map)
        end

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

      # Load the syslog_protocol gem, which builds the packets for remote syslog.
      # Called when a syslog formatter is created, so the gem is only needed by applications
      # that log to a remote syslog server.
      def self.require_syslog_protocol
        require "syslog_protocol"
      rescue LoadError
        raise LoadError,
              "Gem syslog_protocol is required for remote logging using the Syslog protocol. " \
              'Please add the gem "syslog_protocol" to your Gemfile.'
      end

      # Create a Syslog Log Formatter
      #
      # Parameters:
      #   facility: [Integer]
      #     One of the ::Syslog::LOG_* facility constants, for example ::Syslog::LOG_LOCAL0.
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
      #   max_size: [Integer]
      #     Maximum size of each syslog packet, in bytes.
      #     Default: DEFAULT_MAX_SIZE (1024)
      #
      #   Example:
      #     # Change the warn level to LOG_NOTICE level instead of a the default of LOG_WARNING.
      #     SemanticLogger.add_appender(appender: :syslog, level_map: {warn: ::Syslog::LOG_NOTICE})
      def initialize(facility: LOG_USER, level_map: LevelMap.new, max_size: DEFAULT_MAX_SIZE,
                     escape_control_chars: true, **args)
        self.class.require_syslog_protocol

        self.facility  = facility
        self.level_map = level_map
        @max_size      = max_size
        # Syslog frames records with a separator, so embedded newlines or other
        # control characters in untrusted log data can forge or split records.
        # Default to escaping them, overridable for backwards compatibility.
        super(escape_control_chars: escape_control_chars, **args)
      end

      # Set the facility to one of the ::Syslog::LOG_* facility constants.
      # Raises ArgumentError for any other value, so that a mistake surfaces here rather than on
      # every log entry.
      def facility=(facility)
        @facility_number = Syslog.facility_number(facility)
        @facility        = facility
      end

      # Set the map of log levels to syslog severities, as a LevelMap or a Hash of overrides.
      def level_map=(level_map)
        @level_map = LevelMap.build(level_map)
      end

      # Time is part of the syslog packet and is not included in the formatted message.
      def time
        nil
      end

      def call(log, logger)
        # The individual fields are already escaped. Also escape the newlines that the
        # exception and its backtrace are laid out with, so that a record never spans more
        # than one line, which a receiver framing records by newline would split.
        message = escape_control_characters(super)
        create_syslog_packet(message)
      end

      private

      # Create Syslog Packet
      def create_syslog_packet(message)
        packet          = SyslogProtocol::Packet.new
        packet.hostname = logger.host
        packet.facility = @facility_number
        packet.tag      = logger.application.delete(" ")
        packet.content  = message
        packet.time     = log.time
        packet.severity = level_map[log.level]
        packet.assemble(@max_size)
      end

      # Off by default, so that existing syslog records do not change.
      def default_log_exception_details
        false
      end
    end
  end
end
