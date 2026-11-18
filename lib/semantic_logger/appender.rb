module SemanticLogger
  module Appender
    # @formatter:off
    autoload :Async,               "semantic_logger/appender/async"
    autoload :Bugsnag,             "semantic_logger/appender/bugsnag"
    autoload :CloudwatchLogs,      "semantic_logger/appender/cloudwatch_logs"
    autoload :Elasticsearch,       "semantic_logger/appender/elasticsearch"
    autoload :ElasticsearchBase,   "semantic_logger/appender/elasticsearch_base"
    autoload :ElasticsearchHttp,   "semantic_logger/appender/elasticsearch_http"
    autoload :File,                "semantic_logger/appender/file"
    autoload :Graylog,             "semantic_logger/appender/graylog"
    autoload :Honeybadger,         "semantic_logger/appender/honeybadger"
    autoload :HoneybadgerInsights, "semantic_logger/appender/honeybadger_insights"
    autoload :IO,                  "semantic_logger/appender/io"
    autoload :Kafka,               "semantic_logger/appender/kafka"
    autoload :Sentry,              "semantic_logger/appender/sentry"
    autoload :Http,                "semantic_logger/appender/http"
    autoload :MongoDB,             "semantic_logger/appender/mongodb"
    autoload :NewRelic,            "semantic_logger/appender/new_relic"
    autoload :NewRelicLogs,        "semantic_logger/appender/new_relic_logs"
    autoload :Opensearch,          "semantic_logger/appender/opensearch"
    autoload :OpenTelemetry,       "semantic_logger/appender/open_telemetry"
    autoload :Rabbitmq,            "semantic_logger/appender/rabbitmq"
    autoload :Splunk,              "semantic_logger/appender/splunk"
    autoload :SplunkHttp,          "semantic_logger/appender/splunk_http"
    autoload :Syslog,              "semantic_logger/appender/syslog"
    autoload :Tcp,                 "semantic_logger/appender/tcp"
    autoload :TextOutput,          "semantic_logger/appender/text_output"
    autoload :Udp,                 "semantic_logger/appender/udp"
    autoload :Wrapper,             "semantic_logger/appender/wrapper"
    autoload :SentryRuby,          "semantic_logger/appender/sentry_ruby"
    autoload :Loki,                "semantic_logger/appender/loki"
    # @formatter:on

    # Returns [SemanticLogger::Subscriber] appender for the supplied options
    def self.factory(async: false, batch: nil,
                     max_queue_size: 10_000, lag_check_interval: 1_000, lag_threshold_s: 30,
                     batch_size: 300, batch_seconds: 5,
                     non_blocking: false, dropped_message_report_seconds: 30,
                     async_max_retries: 100,
                     **args,
                     &)
      appender = build(**args, &)

      # If appender implements #batch, then it should use the batch proxy by default,
      # unless the appender opts out of batching by default (e.g. the HTTP appender).
      batch    = true if batch.nil? && appender.respond_to?(:batch) && appender.batch_by_default?

      if batch == true
        Appender::Async.new(
          appender:                       appender,
          batch:                          true,
          max_queue_size:                 max_queue_size,
          lag_threshold_s:                lag_threshold_s,
          batch_size:                     batch_size,
          batch_seconds:                  batch_seconds,
          non_blocking:                   non_blocking,
          dropped_message_report_seconds: dropped_message_report_seconds,
          async_max_retries:              async_max_retries
        )
      elsif async == true
        Appender::Async.new(
          appender:                       appender,
          max_queue_size:                 max_queue_size,
          lag_check_interval:             lag_check_interval,
          lag_threshold_s:                lag_threshold_s,
          non_blocking:                   non_blocking,
          dropped_message_report_seconds: dropped_message_report_seconds,
          async_max_retries:              async_max_retries
        )
      else
        appender
      end
    end

    # Returns [Subscriber] instance from the supplied options.
    def self.build(io: nil, file_name: nil, appender: nil, metric: nil, logger: nil, **args, &)
      if file_name
        SemanticLogger::Appender::File.new(file_name, **args, &)
      elsif io
        SemanticLogger::Appender::IO.new(io, **args, &)
      elsif logger
        SemanticLogger::Appender::Wrapper.new(logger: logger, **args, &)
      elsif appender
        if appender.is_a?(Symbol)
          SemanticLogger::Utils.constantize_symbol(appender).new(**args, &)
        elsif appender.is_a?(Subscriber)
          subscriber_instance(:appender, appender, **args, &)
        else
          raise(ArgumentError,
                "Parameter :appender must be either a Symbol or an object derived from " \
                "SemanticLogger::Subscriber, not: #{appender.inspect}")
        end
      elsif metric
        if metric.is_a?(Symbol)
          SemanticLogger::Utils.constantize_symbol(metric, "SemanticLogger::Metric").new(**args, &)
        elsif metric.is_a?(Subscriber)
          subscriber_instance(:metric, metric, **args, &)
        else
          raise(ArgumentError,
                "Parameter :metric must be either a Symbol or an object derived from " \
                "SemanticLogger::Subscriber, not: #{metric.inspect}")
        end
      else
        raise(ArgumentError,
              "To create an appender it must supply one of the following: " \
              ":io, :file_name, :appender, :metric, or :logger")
      end
    end

    private_class_method :build

    # Returns [Subscriber] the appender or metric subscriber supplied as an instance, with the `option` that named it,
    # `:appender` or `:metric`, as it is, since it was created with its own options. The options and block that .build
    # would hand to an appender that it creates are not used, so reports a deprecation warning that names each one,
    # since v6 raises ArgumentError for them. An option whose value is nil, the default of a Subscriber, sets nothing,
    # so it is not reported, and v6 must not raise for it either, so that a caller can pass on its optional settings.
    # Since an option of .factory that is misspelled arrives here too, the warning names the options that do apply to
    # an instance. Remove in v6, raising ArgumentError in its place.
    def self.subscriber_instance(option, subscriber, **args)
      ignored = args.compact.keys.map { |key| "#{key}:" }
      ignored.unshift("the formatter block") if block_given?
      return subscriber if ignored.empty?

      list    = ignored.size < 3 ? ignored.join(" and ") : "#{ignored[0..-2].join(', ')}, and #{ignored.last}"
      pronoun = ignored.one? ? "it" : "them"
      Deprecation.warn(
        "add_appender ignores #{list} when #{option}: is a Subscriber instance (#{subscriber.class}), " \
        "and v6 raises ArgumentError for #{pronoun}. Set #{pronoun} on the instance itself; " \
        "only async:, batch:, and the queue options of add_appender apply to an instance."
      )
      subscriber
    end
    private_class_method :subscriber_instance
  end
end
