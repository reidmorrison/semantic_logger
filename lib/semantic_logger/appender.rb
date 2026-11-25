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
    autoload :TcpClientOptions,    "semantic_logger/appender/tcp_client_options"
    autoload :TextOutput,          "semantic_logger/appender/text_output"
    autoload :Udp,                 "semantic_logger/appender/udp"
    autoload :Wrapper,             "semantic_logger/appender/wrapper"
    autoload :SentryRuby,          "semantic_logger/appender/sentry_ruby"
    autoload :Loki,                "semantic_logger/appender/loki"
    # @formatter:on

    # Returns [SemanticLogger::Subscriber] appender for the supplied options
    #
    # Raises ArgumentError when the appender is to be batched, with `batch: true` or by default, see
    # Subscriber#batch_by_default?, and it says why it cannot be, see Subscriber#batch_refusal. When it fails
    # after .build, it first closes the appender that .build says it created, see .close_created.
    def self.factory(async: false, batch: nil,
                     max_queue_size: 10_000, lag_check_interval: 1_000, lag_threshold_s: 30,
                     batch_size: 300, batch_seconds: 5,
                     non_blocking: false, dropped_message_report_seconds: 30,
                     async_max_retries: 100,
                     **args,
                     &)
      appender, created = build(**args, &)

      # If appender implements #batch, then it should use the batch proxy by default,
      # unless the appender opts out of batching by default (e.g. the HTTP appender).
      batch    = true if batch.nil? && appender.respond_to?(:batch) && appender.batch_by_default?

      if batch == true
        refusal = appender.batch_refusal
        raise(ArgumentError, "add_appender cannot batch #{appender.class}: #{refusal}") if refusal

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
    rescue Exception
      close_created(appender) if created
      raise
    end

    # Closes the appender that .build created, since .factory failed after creating it, such as when the appender
    # cannot be batched, and nothing else holds it, yet it may have opened its destination, such as a connection.
    # An error from closing it is ignored, so that .factory raises the one that it failed with.
    def self.close_created(appender)
      appender.close
    rescue StandardError
      nil
    end
    private_class_method :close_created

    # Returns [Subscriber, true | false] the appender for the supplied options, and whether .build created both it
    # and its destination, so that nothing else holds them, and .factory closes it when it fails afterwards (see
    # .close_created): true for the appender for `file_name:`, or one named by a Symbol as `appender:` or `metric:`.
    # False for a Subscriber instance that the caller supplied as `appender:` or `metric:`, and for the appender that
    # writes to the caller's own `io:` or `logger:`: closing the one for `logger:` closes that logger, and the stream
    # it writes to, such as $stdout.
    #
    # It adds one destination, the first of file_name:, io:, logger:, appender:, and metric: that is given, in that
    # order, and ignores any other, see .report_ignored_destinations.
    def self.build(io: nil, file_name: nil, appender: nil, metric: nil, logger: nil, **args, &)
      # Named in the order of the if / elsif chain below, which adds the first one given: keep the two in step.
      report_ignored_destinations(file_name: file_name, io: io, logger: logger, appender: appender, metric: metric)

      if file_name
        [SemanticLogger::Appender::File.new(file_name, **args, &), true]
      elsif io
        [SemanticLogger::Appender::IO.new(io, **args, &), false]
      elsif logger
        [SemanticLogger::Appender::Wrapper.new(logger: logger, **args, &), false]
      elsif appender
        if appender.is_a?(Symbol)
          [SemanticLogger::Utils.constantize_symbol(appender).new(**args, &), true]
        elsif appender.is_a?(Subscriber)
          [subscriber_instance(:appender, appender, **args, &), false]
        else
          raise(ArgumentError,
                "Parameter :appender must be either a Symbol or an object derived from " \
                "SemanticLogger::Subscriber, not: #{appender.inspect}")
        end
      elsif metric
        if metric.is_a?(Symbol)
          [SemanticLogger::Utils.constantize_symbol(metric, "SemanticLogger::Metric").new(**args, &), true]
        elsif metric.is_a?(Subscriber)
          [subscriber_instance(:metric, metric, **args, &), false]
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

    # Returns [SemanticLogger::Base] the supplied logger, ready to be an internal logger: the one that
    # Semantic Logger reports its own problems to (see Processor.logger=).
    #
    # An internal logger is named after whatever reports to it, logs at :trace, and takes an
    # exception after the message, as every Semantic Logger appender does. So an appender, such as the
    # default IO appender, or any other logger that logs at :trace, is returned as it is. Any other
    # logger, such as a Ruby or Rails Logger, does none of that, so it is wrapped in a Wrapper
    # appender, which writes each report to it as text, with the exception. Its own level then decides
    # which reports it writes, apart from the :trace reports, which are below its lowest level, :debug,
    # so are left out.
    #
    # Returns nil for nil or false, which restores the default internal logger.
    #
    # Raises ArgumentError for a SemanticLogger::Logger: it logs back into the processor, so the
    # report of an appender that fails would go to that appender, fail again, and be reported again.
    def self.internal_logger(logger)
      return unless logger

      if logger.is_a?(SemanticLogger::Logger)
        raise(ArgumentError,
              "A SemanticLogger::Logger cannot be the internal logger, since its reports of a failing " \
              "appender would be logged to that appender. Use an appender, such as " \
              "SemanticLogger::Appender::IO.new($stderr), or a Ruby Logger.")
      end
      return logger if logger.respond_to?(:trace)

      SemanticLogger::Appender::Wrapper.new(logger: logger, level: :debug)
    end

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

      pronoun = ignored.one? ? "it" : "them"
      Deprecation.warn(
        "add_appender ignores #{word_list(ignored)} when #{option}: is a Subscriber instance (#{subscriber.class}), " \
        "and v6 raises ArgumentError for #{pronoun}. Set #{pronoun} on the instance itself; " \
        "only async:, batch:, and the queue options of add_appender apply to an instance."
      )
      subscriber
    end
    private_class_method :subscriber_instance

    # Reports a deprecation warning when .build is given more than one of the destinations, in the order in which it
    # takes the first one, naming the one that it uses and the others, which it ignores, since v6 raises ArgumentError
    # for them. A destination given as nil, or false, is not one, as .build has always taken it, so that a caller can
    # pass on settings of which only one is set, such as `file_name: options[:file_name], io: options[:io]`, and v6
    # must not raise for it either. Remove in v6, raising ArgumentError in its place.
    def self.report_ignored_destinations(**destinations)
      used, *ignored = destinations.filter_map { |name, value| "#{name}:" if value }
      return if ignored.empty?

      Deprecation.warn(
        "add_appender adds one destination, so it uses #{used} and ignores #{word_list(ignored)}, " \
        "and v6 raises ArgumentError when given more than one. Call add_appender once for each destination."
      )
    end
    private_class_method :report_ignored_destinations

    # Returns [String] the words as a list in a sentence, such as "a", "a and b", or "a, b, and c".
    def self.word_list(words)
      words.size < 3 ? words.join(" and ") : "#{words[0..-2].join(', ')}, and #{words.last}"
    end
    private_class_method :word_list
  end
end
