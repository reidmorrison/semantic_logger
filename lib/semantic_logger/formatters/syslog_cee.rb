begin
  require "syslog_protocol"
rescue LoadError
  raise LoadError,
        'Gem syslog_protocol is required for remote logging using the Syslog protocol. Please add the gem "syslog_protocol" to your Gemfile.'
end

module SemanticLogger
  module Formatters
    class SyslogCee < Raw
      attr_accessor :level_map, :facility, :max_size

      # CEE JSON Syslog format
      #   Untested prototype code. Based on documentation only.
      #   If this works for you, please let us know by opening an issue.
      #
      # Parameters:
      #   facility: [Integer]
      #     Default: ::Syslog::LOG_USER
      #
      #   level_map: [Hash | SemanticLogger::Formatters::Syslog::LevelMap]
      #     Supply a custom map of SemanticLogger levels to syslog levels.
      #
      # Example:
      #   # Log via udp to a remote syslog server on host: `server1` and port `8514`, using the CEE format.
      #   SemanticLogger.add_appender(appender: :syslog, formatter: :syslog_cee, url: 'udp://server1:8514')
      def initialize(facility: ::Syslog::LOG_USER, level_map: SemanticLogger::Formatters::Syslog::LevelMap.new, max_size: Integer)
        @facility  = facility
        @level_map = level_map.is_a?(SemanticLogger::Formatters::Syslog::LevelMap) ? level_map : SemanticLogger::Formatters::Syslog::LevelMap.new(level_map)
        @max_size = max_size
        super()
      end

      # Time is part of the syslog packet and is not included in the formatted message.
      def time
      end

      def call(log, logger)
        hash = super(log, logger)
        create_syslog_packet("@cee: #{hash.to_json}")
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
