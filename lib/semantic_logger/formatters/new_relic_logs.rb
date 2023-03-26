require "json"

begin
  require "newrelic_rpm"
rescue LoadError
  raise LoadError, 'Gem newrelic_rpm is required for logging to New Relic. Please add the gem "newrelic_rpm" to your Gemfile.'
end

raise "NewRelic::Agent.linking_metadata is not defined. Please update newrelic_rpm gem version" unless NewRelic::Agent.respond_to?(:linking_metadata)

raise "NewRelic::Agent::Tracer.current_span_id is not defined. Please update newrelic_rpm gem version" unless NewRelic::Agent::Tracer.respond_to?(:current_span_id)

raise "NewRelic::Agent::Tracer.current_trace_id is not defined. Please update newrelic_rpm gem version" unless NewRelic::Agent::Tracer.respond_to?(:current_trace_id)

module SemanticLogger
  module Formatters
    # Formatter for reporting to NewRelic's Logger
    #
    # New Relic's logs do not support custom attributes out of the box, and therefore these
    # have to be put into a single JSON serialized string under the +message+ key.
    #
    # In particular the following fields of the log object are serialized under the +message+
    # key that's sent to NewRelic:
    #
    # * message
    # * tags
    # * named_tags
    # * payload
    # * metric
    # * metric_amount
    # * environment
    # * application
    #
    # == New Relic Attributes not Supported
    # * thread.id
    # * class.name
    # * method.name
    #
    # == Reference
    # * Logging specification
    #   * https://github.com/newrelic/newrelic-exporter-specs/tree/master/logging
    #
    # * Metadata APIs
    #   * https://www.rubydoc.info/gems/newrelic_rpm/NewRelic/Agent#linking_metadata-instance_method
    #   * https://www.rubydoc.info/gems/newrelic_rpm/NewRelic/Agent/Tracer#current_trace_id-class_method
    #   * https://www.rubydoc.info/gems/newrelic_rpm/NewRelic/Agent/Tracer#current_span_id-class_method
    #
    class NewRelicLogs < Raw
      def initialize(**args)
        args.delete(:time_key)
        args.delete(:time_format)

        super(time_key: :timestamp, time_format: :ms, **args)
      end

      def call(log, logger)
        hash = super(log, logger)

        message = {
          message:    hash[:message].to_s,
          tags:       hash[:tags] || [],
          named_tags: hash[:named_tags] || {},

          **hash.slice(:metric, :metric_amount, :environment, :application, :payload)
        }

        message.merge!(duration: hash[:duration_ms]) if hash.key?(:duration_ms)
        message.merge!(duration_human: hash[:duration]) if hash.key?(:duration)

        result = {
          **new_relic_metadata,
          message:       message.to_json,
          timestamp:     hash[:timestamp].to_i,
          "log.level":   log.level.to_s.upcase,
          "logger.name": log.name,
          "thread.name": log.thread_name.to_s
        }

        if hash[:exception]
          result.merge!(
            "error.message": hash[:exception][:message],
            "error.class":   hash[:exception][:name],
            "error.stack":   hash[:exception][:stack_trace].join("\n")
          )
        end

        if hash[:file]
          result.merge!(
            "file.name":   hash[:file],
            "line.number": hash[:line].to_s
          )
        end

        result
      end

      private

      def new_relic_metadata
        {
          "trace.id": NewRelic::Agent::Tracer.current_trace_id,
          "span.id":  NewRelic::Agent::Tracer.current_span_id,
          **NewRelic::Agent.linking_metadata
        }.reject { |_k, v| v.nil? }.
          map { |k, v| [k.to_sym, v] }.to_h
      end
    end
  end
end
