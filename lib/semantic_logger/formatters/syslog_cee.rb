module SemanticLogger
  module Formatters
    class SyslogCee < Raw
      attr_accessor :max_size
      attr_reader :facility, :level_map

      # CEE JSON Syslog format
      #   Untested prototype code. Based on documentation only.
      #   If this works for you, please let us know by opening an issue.
      #
      # Parameters:
      #   facility: [Integer]
      #     One of the ::Syslog::LOG_* facility constants, for example ::Syslog::LOG_LOCAL0.
      #     Default: SemanticLogger::Formatters::Syslog::LOG_USER
      #
      #   level_map: [Hash | SemanticLogger::Formatters::Syslog::LevelMap]
      #     Supply a custom map of SemanticLogger levels to syslog levels.
      #
      #   max_size: [Integer]
      #     Maximum size of each syslog packet, in bytes.
      #     Default: SemanticLogger::Formatters::Syslog::DEFAULT_MAX_SIZE (1024)
      #
      # Example:
      #   # Log via udp to a remote syslog server on host: `server1` and port `8514`, using the CEE format.
      #   SemanticLogger.add_appender(appender: :syslog, formatter: :syslog_cee, url: 'udp://server1:8514')
      def initialize(facility: SemanticLogger::Formatters::Syslog::LOG_USER, level_map: SemanticLogger::Formatters::Syslog::LevelMap.new,
                     max_size: SemanticLogger::Formatters::Syslog::DEFAULT_MAX_SIZE)
        SemanticLogger::Formatters::Syslog.require_syslog_protocol

        self.facility  = facility
        self.level_map = level_map
        @max_size      = max_size
        super()
      end

      # Set the facility to one of the ::Syslog::LOG_* facility constants.
      # Raises ArgumentError for any other value, so that a mistake surfaces here rather than on
      # every log entry.
      def facility=(facility)
        @facility_number = SemanticLogger::Formatters::Syslog.facility_number(facility)
        @facility        = facility
      end

      # Set the map of log levels to syslog severities, as a LevelMap or a Hash of overrides.
      def level_map=(level_map)
        @level_map = SemanticLogger::Formatters::Syslog::LevelMap.build(level_map)
      end

      # Time is part of the syslog packet and is not included in the formatted message.
      def time
      end

      def call(log, logger)
        hash = super
        create_syslog_packet("@cee: #{Utils.to_json(hash)}")
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
    end
  end
end
