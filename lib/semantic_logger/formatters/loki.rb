require "json"

module SemanticLogger
  module Formatters
    class Loki < Base
      attr_accessor :stream, :payload_value

      # Returns [String] a single JSON log
      def call(log, logger)
        self.logger = logger
        self.log = log

        {streams: [build_stream]}.to_json
      end

      # Returns [String] a JSON batch of logs
      def batch(logs, logger)
        self.logger = logger

        streams = logs.map do |log|
          self.log = log
          build_stream
        end

        {streams: streams}.to_json
      end

      private

      def build_stream
        self.stream = {stream: {pid: pid}, values: [[]]}

        application
        environment
        host
        level
        thread
        tags
        named_tags
        context
        time
        message
        payload
        metric
        duration
        exception

        stream[:values][0] << payload_value
        stream
      end

      def host
        stream[:stream][:host] = logger.host if log_host && logger.host.to_s
      end

      def application
        stream[:stream][:application] = logger.application if log_application && logger&.application
      end

      def environment
        stream[:stream][:environment] = logger.environment if log_environment && logger&.environment
      end

      def level
        stream[:stream][:level] = log.level
      end

      def thread
        stream[:stream][:thread] = log.thread_name if log.thread_name
      end

      def tags
        stream[:stream][:tags] = log.tags if log.tags.respond_to?(:empty?) && !log.tags.empty?
      end

      def named_tags
        stream[:stream].merge!(log.named_tags) if log.named_tags.respond_to?(:empty?) && !log.named_tags.empty?
      end

      def context
        return unless log.context && !log.context.empty?

        log.context.each do |key, value|
          serialized_value = if value.is_a?(Hash)
                               value.to_json
                             else
                               value.to_s
                             end

          stream[:stream].merge!(key.to_s => serialized_value)
        end
      end

      def time
        stream[:values][0] << format_time(log)
      end

      def message
        stream[:values][0] << (log.message ? log.cleansed_message : "")
      end

      def format_time(log)
        log.time.strftime("%s%N")
      end

      def payload
        self.payload_value = if log.payload.respond_to?(:empty?) && !log.payload.empty?
                               # Loki only accepts strings as key and values
                               stringify_hash(log.payload)
                             else
                               {}
                             end
      end

      def metric
        return unless log.metric

        payload_value[:metric] = log.metric
        payload_value[:metric_value] = log.metric_amount
      end

      def duration
        return unless log.duration

        payload_value[:duration] = log.duration.to_s
        payload_value[:duration_human] = log.duration_human
      end

      def exception
        return unless log.exception

        payload_value.merge!(
          exception_name:    log.exception.class.name,
          exception_message: log.exception.message,
          stack_trace:       log.exception.backtrace.to_s
        )
      end

      def stringify_hash(hash)
        result = {}

        hash.each do |key, value|
          string_key = key.to_s

          result[string_key] = case value
                               when Hash
                                 JSON.generate(stringify_hash(value))
                               else
                                 value.to_s
                               end
        end

        result
      end
    end
  end
end
