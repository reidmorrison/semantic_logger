module SemanticLogger
  module Appender
    # @formatter:off
    autoload :Async,             'semantic_logger/appender/async'
    autoload :AsyncBatch,        'semantic_logger/appender/async_batch'
    autoload :Bugsnag,           'semantic_logger/appender/bugsnag'
    autoload :Elasticsearch,     'semantic_logger/appender/elasticsearch'
    autoload :ElasticsearchHttp, 'semantic_logger/appender/elasticsearch_http'
    autoload :File,              'semantic_logger/appender/file'
    autoload :Graylog,           'semantic_logger/appender/graylog'
    autoload :Honeybadger,       'semantic_logger/appender/honeybadger'
    autoload :Kafka,             'semantic_logger/appender/kafka'
    autoload :Sentry,            'semantic_logger/appender/sentry'
    autoload :Http,              'semantic_logger/appender/http'
    autoload :MongoDB,           'semantic_logger/appender/mongodb'
    autoload :NewRelic,          'semantic_logger/appender/new_relic'
    autoload :Signalfx,          'semantic_logger/appender/signalfx'
    autoload :Splunk,            'semantic_logger/appender/splunk'
    autoload :SplunkHttp,        'semantic_logger/appender/splunk_http'
    autoload :Statsd,            'semantic_logger/appender/statsd'
    autoload :Syslog,            'semantic_logger/appender/syslog'
    autoload :Tcp,               'semantic_logger/appender/tcp'
    autoload :Udp,               'semantic_logger/appender/udp'
    autoload :Wrapper,           'semantic_logger/appender/wrapper'
    # @formatter:on

    # DEPRECATED, use SemanticLogger::AnsiColors
    AnsiColors = SemanticLogger::AnsiColors

    # DEPRECATED: use SemanticLogger::Formatters::Color.new
    def self.colorized_formatter
      SemanticLogger::Formatters::Color.new
    end

    # DEPRECATED: use SemanticLogger::Formatters::Json.new
    def self.json_formatter
      SemanticLogger::Formatters::Json.new
    end

    # Returns [SemanticLogger::Subscriber] appender for the supplied options
    def self.factory(options, &block)
      options = options.dup
      async   = options.delete(:async)
      batch   = options.delete(:batch)

      # Extract batch and async options
      proxy_options = {}
      ASYNC_OPTION_KEYS.each { |key| proxy_options[key] = options.delete(key) if options.key?(key) }

      appender = build(options, &block)

      # If appender implements #batch, then it should use the batch proxy by default.
      batch    = true if batch.nil? && appender.respond_to?(:batch)

      if batch == true
        proxy_options[:appender] = appender
        Appender::AsyncBatch.new(proxy_options)
      elsif async == true
        proxy_options[:appender] = appender
        Appender::Async.new(proxy_options)
      else
        appender
      end
    end

    private

    ASYNC_OPTION_KEYS = [:max_queue_size, :lag_threshold_s, :batch_size, :batch_seconds, :lag_check_interval]

    # Returns [Subscriber] instance from the supplied options.
    def self.build(options, &block)
      if options[:io] || options[:file_name]
        SemanticLogger::Appender::File.new(options, &block)
      elsif appender = options.delete(:appender)
        if appender.is_a?(Symbol)
          SemanticLogger::Utils.constantize_symbol(appender).new(options)
        elsif appender.is_a?(Subscriber)
          appender
        else
          raise(ArgumentError, "Parameter :appender must be either a Symbol or an object derived from SemanticLogger::Subscriber, not: #{appender.inspect}")
        end
      elsif options[:logger]
        SemanticLogger::Appender::Wrapper.new(options, &block)
      end
    end

  end
end
