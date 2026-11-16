require "json"

module SemanticLogger
  module Formatters
    class Loki < Base
      attr_accessor :stream, :payload_value

      # The names of the structured metadata that this formatter writes itself. A payload key that
      # Loki would store under one of these names is written with PAYLOAD_PREFIX, as in
      # `payload_duration`, whether or not the entry has that field, so that each name always holds
      # this formatter's value. Loki keeps only the last value of a name written twice, and stores
      # a name such as `metric.value` as `metric_value` (see OWN_NAME), so the payload's value
      # would otherwise be lost, or replace this formatter's.
      OWN_KEYS = %w[
        metric metric_value dimensions duration duration_human exception_name exception_message
        stack_trace
      ].freeze

      # Matches a name that Loki stores as one of OWN_KEYS.
      #
      # Loki replaces each character of a name other than an ASCII letter, digit, or underscore
      # with an underscore, and writes two or more underscores in a row as one. So `metric.value`,
      # `metric__value`, and `metric` followed by a zero width space and `value` are all stored as
      # `metric_value`: each underscore of an own name stands for any run of those characters.
      OWN_NAME = /\A(?:#{OWN_KEYS.map { |key| key.gsub('_', '[^A-Za-z0-9]+') }.join('|')})\z/

      # The prefix of a payload key named like one of OWN_KEYS. The :logfmt and :open_telemetry
      # formatters write `payload.`, which Loki would store as `payload_`.
      PAYLOAD_PREFIX = "payload_".freeze

      # Returns [String] a single JSON log
      def call(log, logger)
        self.logger = logger
        self.log = log

        Utils.to_json({streams: [build_stream]})
      end

      # Returns [String] a JSON batch of logs
      def batch(logs, logger)
        self.logger = logger

        streams = logs.map do |log|
          self.log = log
          build_stream
        end

        Utils.to_json({streams: streams})
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
          stream[:stream].merge!(key.to_s => loki_value(value))
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
        self.payload_value = if !log.payload?
                               {}
                             elsif log.payload.is_a?(Hash)
                               payload_metadata(log.payload)
                             else
                               # A log call can supply any value as the payload, such as a String
                               # parsed from a request body.
                               {"payload" => loki_value(log.payload)}
                             end
      end

      # Every value is a String, since structured metadata only holds Strings: Loki rejects the
      # whole push, with every entry in it, when one holds a number or null. The dimensions are a
      # single value, as JSON.
      def metric
        return unless log.metric

        payload_value[:metric]       = loki_value(log.metric)
        payload_value[:metric_value] = number_text(log.metric_amount) if log.metric_amount
        payload_value[:dimensions]   = loki_value(log.dimensions) if log.dimensions?
      end

      def duration
        return unless log.duration

        payload_value[:duration] = number_text(log.duration)
        payload_value[:duration_human] = log.duration_human
      end

      # Returns [String] the number as LogQL reads it, to compare it or `unwrap` it: an Integer as
      # it is, and any other number as a Float, which is how LogQL holds it. A Rational's own text,
      # such as `3/2`, would make every LogQL query that unwraps it fail, and a BigDecimal's, such
      # as `0.25e1`, is not how anyone writes a number.
      def number_text(number)
        number.is_a?(Integer) ? number.to_s : number.to_f.to_s
      end

      # The stack trace is one line per frame, followed by each exception that caused it, as the
      # text formatters write it.
      #
      # The name and message are Strings too: the class's name, or, for an anonymous class, which
      # has none, the class as the text formatters write it, such as `#<Class:0x000...>`. A
      # #message that returns nil, or raises, is replaced as Utils.exception_message replaces it.
      def exception
        return unless log.exception

        payload_value.merge!(
          exception_name:    (log.exception.class.name || log.exception.class).to_s,
          exception_message: Utils.exception_message(log.exception),
          stack_trace:       exception_backtrace
        )
      end

      # Returns [Hash] the payload as structured metadata, with String keys and values, since Loki
      # only accepts Strings.
      #
      # A key that Loki would store as one of this formatter's own names (see OWN_KEYS) is written
      # with PAYLOAD_PREFIX, after the other keys, and with it again while that name is already a
      # key of the payload, so that no value is lost. Such a key is converted as Utils.to_json
      # converts it, since one that is not ASCII-compatible, such as UTF-16, cannot be joined with
      # the prefix.
      def payload_metadata(hash)
        metadata = {}
        own      = nil
        hash.each_pair do |key, value|
          name = key.to_s
          if own_key?(name)
            (own ||= []) << [name, value]
          else
            metadata[name] = loki_value(value)
          end
        end
        own&.each do |name, value|
          name = PAYLOAD_PREFIX + Utils.encode_utf8_string(name)
          name = PAYLOAD_PREFIX + name while metadata.key?(name)
          metadata[name] = loki_value(value)
        end
        metadata
      end

      # Whether Loki would store the name as one of this formatter's own names (see OWN_NAME).
      #
      # A name with characters outside ASCII is matched as Utils.to_json writes it: in UTF-8,
      # without invalid bytes, which matching it as it is could raise for.
      def own_key?(name)
        name = Utils.encode_utf8_string(name) unless name.ascii_only?
        name.match?(OWN_NAME)
      end

      # Returns [String] the value as Loki accepts it.
      #
      # A structure is written once, as JSON, depth-limited and repaired by Utils.to_json.
      # Encoding each nested level into a String that the next level encodes again doubled the
      # escaping at every level, so a request parameter 30 levels deep produced gigabytes. A
      # structure's #to_s is its #inspect, which would also expose the instance variables of any
      # object it holds.
      def loki_value(value)
        if value.is_a?(String)
          value
        elsif Utils.structure?(value)
          Utils.to_json(value)
        else
          value.to_s
        end
      end
    end
  end
end
