# Mocked NewRelic::Agent used for testing

module NewRelic
  module Agent
    module LogEventAggregator
      def self.record(message, level)
      end
    end

    def self.agent
      self
    end

    def self.log_event_aggregator
      LogEventAggregator
    end

    def self.notice_error(message, hash)
    end

    def self.record_metric(name, secoonds)
    end

    def self.increment_metric(name, count = 1)
    end

    class << self
      # this isn't part of the real NewRelic Agent, it's just used to avoid
      # polluting log context in tests that don't expect it
      attr_accessor :metadata_enabled
    end

    def self.linking_metadata
      if metadata_enabled
        {"entity.name" => "Entity Name", "entity.type" => "SERVICE", "hostname" => "hostname"}
      else
        {}
      end
    end

    module Tracer
      def self.current_trace_id
      end

      def self.current_span_id
      end
    end
  end
end
