module SemanticLogger
  module Appender
    # @formatter:off
    autoload :Async,               "semantic_logger/appender/async"
    autoload :AsyncBatch,          "semantic_logger/appender/async_batch"
    autoload :Bugsnag,             "semantic_logger/appender/bugsnag"
    autoload :Elasticsearch,       "semantic_logger/appender/elasticsearch"
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
    autoload :Rabbitmq,            "semantic_logger/appender/rabbitmq"
    autoload :Splunk,              "semantic_logger/appender/splunk"
    autoload :SplunkHttp,          "semantic_logger/appender/splunk_http"
    autoload :Syslog,              "semantic_logger/appender/syslog"
    autoload :Tcp,                 "semantic_logger/appender/tcp"
    autoload :Udp,                 "semantic_logger/appender/udp"
    autoload :Wrapper,             "semantic_logger/appender/wrapper"
    autoload :SentryRuby,          "semantic_logger/appender/sentry_ruby"
    # @formatter:on

    # Returns [SemanticLogger::Subscriber] appender for the supplied options
    def self.factory(async: false, batch: nil,
                     max_queue_size: 10_000, lag_check_interval: 1_000, lag_threshold_s: 30,
                     batch_size: 300, batch_seconds: 5,
                     **args,
                     &block)
      appender = build(**args, &block)

      # If appender implements #batch, then it should use the batch proxy by default.
      batch    = true if batch.nil? && appender.respond_to?(:batch)

      if batch == true
        Appender::AsyncBatch.new(
          appender:        appender,
          max_queue_size:  max_queue_size,
          lag_threshold_s: lag_threshold_s,
          batch_size:      batch_size,
          batch_seconds:   batch_seconds
        )
      elsif async == true
        Appender::Async.new(
          appender:           appender,
          max_queue_size:     max_queue_size,
          lag_check_interval: lag_check_interval,
          lag_threshold_s:    lag_threshold_s
        )
      else
        appender
      end
    end

    # Returns [Subscriber] instance from the supplied options.
    def self.build(io: nil, file_name: nil, appender: nil, metric: nil, logger: nil, **args, &block)
      if file_name
        SemanticLogger::Appender::File.new(file_name, **args, &block)
      elsif io
        SemanticLogger::Appender::IO.new(io, **args, &block)
      elsif logger
        SemanticLogger::Appender::Wrapper.new(logger: logger, **args, &block)
      elsif appender
        if appender.is_a?(Symbol)
          SemanticLogger::Utils.constantize_symbol(appender).new(**args)
        elsif appender.is_a?(Subscriber)
          appender
        else
          raise(ArgumentError,
                "Parameter :appender must be either a Symbol or an object derived from SemanticLogger::Subscriber, not: #{appender.inspect}")
        end
      elsif metric
        if metric.is_a?(Symbol)
          SemanticLogger::Utils.constantize_symbol(metric, "SemanticLogger::Metric").new(**args)
        elsif metric.is_a?(Subscriber)
          metric
        else
          raise(ArgumentError,
                "Parameter :metric must be either a Symbol or an object derived from SemanticLogger::Subscriber, not: #{appender.inspect}")
        end
      else
        raise(ArgumentError,
              "To create an appender it must supply one of the following: :io, :file_name, :appender, :metric, or :logger")
      end
    end

    private_class_method :build
  end
end
