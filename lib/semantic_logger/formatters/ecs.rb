require "json"
module SemanticLogger
  module Formatters
    # Formatter conforming to the Elastic Common Schema (ECS).
    #
    # Emits log events using the nested field names defined by ECS so that they
    # integrate cleanly with Filebeat and the Elastic stack (Elasticsearch,
    # Kibana) without requiring an ingest pipeline to rename fields.
    #
    # Usage:
    #   SemanticLogger.add_appender(io: $stdout, formatter: :ecs)
    #
    #   # Route the payload, metric, and other SemanticLogger-specific data into
    #   # a custom top-level namespace (default "semantic_logger"):
    #   SemanticLogger.add_appender(io: $stdout, formatter: {ecs: {namespace: "my_app"}})
    #
    #   # Or merge the payload directly into ECS `labels` instead of a namespace:
    #   SemanticLogger.add_appender(io: $stdout, formatter: {ecs: {namespace: nil}})
    #
    # == Field mapping (SemanticLogger -> ECS 8.x)
    #   time                  -> @timestamp        (ISO-8601)
    #   level                 -> log.level
    #   name                  -> log.logger
    #   file_name / line      -> log.origin.file.name / log.origin.file.line
    #   message               -> message
    #   thread_name           -> process.thread.name
    #   pid                   -> process.pid
    #   host                  -> host.hostname
    #   application           -> service.name
    #   environment           -> service.environment
    #   exception             -> error.type / error.message / error.stack_trace
    #   duration              -> event.duration   (nanoseconds, as required by ECS)
    #   tags                  -> tags             (ECS top-level array)
    #   named_tags            -> labels.*         (scalar key/value pairs)
    #   payload               -> <namespace>.*    (or labels.* when namespace is nil)
    #   metric/metric_amount  -> <namespace>.metric / <namespace>.metric_amount
    #
    # == Reference
    #   * https://www.elastic.co/docs/reference/ecs
    #   * https://www.elastic.co/docs/reference/ecs/ecs-custom-fields-in-ecs
    class Ecs < Raw
      # ECS version this formatter targets.
      ECS_VERSION = "8.11.0".freeze

      # namespace: [String|Symbol|nil]
      #   Top-level field set used to hold SemanticLogger-specific data that has
      #   no native ECS home (payload, metric, metric_amount). A proper-noun
      #   namespace is guaranteed never to collide with a current or future ECS
      #   field. Set to nil to merge the payload into ECS `labels` instead.
      #   Default: "semantic_logger"
      attr_reader :namespace

      def initialize(namespace: "semantic_logger", time_format: :iso_8601, time_key: :timestamp, **args)
        @namespace = namespace&.to_sym

        super(time_format: time_format, time_key: time_key, **args)
      end

      # Returns the log event as a single line of ECS-formatted JSON, so it can
      # be written to stdout / a file and shipped by Filebeat or Elastic Agent.
      def call(log, logger)
        Utils.to_json(ecs_hash(super))
      end

      # Returns a batch of log events as a single JSON array.
      def batch(logs, logger)
        "[#{logs.map { |log| call(log, logger) }.join(',')}]"
      end

      private

      # Remap the flat hash built by Raw#call into the nested ECS field layout.
      def ecs_hash(hash)
        result = base(hash)
        result[:process] = process(hash)
        result[:host]    = {hostname: hash[:host]} if hash[:host]
        add_service(result, hash)
        add_origin(result, hash)
        add_event(result, hash)
        result[:tags] = hash[:tags] if hash[:tags]
        add_error(result, hash)
        add_extras(result, hash)
        result
      end

      def base(hash)
        log = {level: hash[:level].to_s}
        log[:logger] = hash[:name] if hash[:name]
        {
          "@timestamp": hash[:timestamp],
          message:      hash[:message],
          ecs:          {version: ECS_VERSION},
          log:          log
        }
      end

      def process(hash)
        result = {pid: hash[:pid]}
        result[:thread] = {name: hash[:thread].to_s} if hash[:thread]
        result
      end

      def add_service(result, hash)
        service = {}
        service[:name]        = hash[:application] if hash[:application]
        service[:environment] = hash[:environment] if hash[:environment]
        result[:service] = service unless service.empty?
      end

      def add_origin(result, hash)
        return unless hash[:file]

        result[:log][:origin] = {file: {name: hash[:file], line: hash[:line]}.compact}
      end

      # ECS event.duration is measured in nanoseconds.
      def add_event(result, hash)
        return unless hash[:duration_ms]

        result[:event] = {duration: (hash[:duration_ms] * 1_000_000).round}
      end

      def add_error(result, hash)
        return unless hash[:exception]

        result[:error] = {
          type:        hash[:exception][:name],
          message:     hash[:exception][:message],
          stack_trace: Array(hash[:exception][:stack_trace]).join("\n")
        }
      end

      # Place SemanticLogger-specific data (payload, metric) that has no native
      # ECS home into the configured namespace, plus named_tags into labels.
      def add_extras(result, hash)
        labels = hash[:named_tags].is_a?(Hash) ? hash[:named_tags].dup : {}

        extra = {}
        extra[:payload]       = hash[:payload] if hash[:payload]
        extra[:metric]        = hash[:metric] if hash[:metric]
        extra[:metric_amount] = hash[:metric_amount] if hash[:metric_amount]

        unless extra.empty?
          namespace ? result[namespace] = extra : labels.merge!(extra)
        end

        result[:labels] = labels unless labels.empty?
      end
    end
  end
end
