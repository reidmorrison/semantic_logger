module SemanticLogger
  module Appender
    # @formatter:off
    autoload :Bugsnag,          'semantic_logger/appender/bugsnag'
    autoload :Elasticsearch,    'semantic_logger/appender/elasticsearch'
    autoload :File,             'semantic_logger/appender/file'
    autoload :Graylog,          'semantic_logger/appender/graylog'
    autoload :Honeybadger,      'semantic_logger/appender/honeybadger'
    autoload :Sentry,           'semantic_logger/appender/sentry'
    autoload :Http,             'semantic_logger/appender/http'
    autoload :MongoDB,          'semantic_logger/appender/mongodb'
    autoload :NewRelic,         'semantic_logger/appender/new_relic'
    autoload :Splunk,           'semantic_logger/appender/splunk'
    autoload :SplunkHttp,       'semantic_logger/appender/splunk_http'
    autoload :Syslog,           'semantic_logger/appender/syslog'
    autoload :Tcp,              'semantic_logger/appender/tcp'
    autoload :Udp,              'semantic_logger/appender/udp'
    autoload :Wrapper,          'semantic_logger/appender/wrapper'
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
    def self.create(options, &block)
      if options[:io] || options[:file_name]
        SemanticLogger::Appender::File.new(options, &block)
      elsif appender = options.delete(:appender)
        if appender.is_a?(Symbol)
          constantize_symbol(appender).new(options)
        elsif appender.is_a?(Subscriber)
          appender
        else
          raise(ArgumentError, "Parameter :appender must be either a Symbol or an object derived from SemanticLogger::Subscriber, not: #{appender.inspect}")
        end
      elsif options[:logger]
        SemanticLogger::Appender::Wrapper.new(options, &block)
      end
    end

    def self.constantize_symbol(symbol, namespace = 'SemanticLogger::Appender')
      klass = "#{namespace}::#{camelize(symbol.to_s)}"
      begin
        if RUBY_VERSION.to_i >= 2
          Object.const_get(klass)
        else
          klass.split('::').inject(Object) { |o, name| o.const_get(name) }
        end
      rescue NameError
        raise(ArgumentError, "Could not convert symbol: #{symbol} to a class in: #{namespace}. Looking for: #{klass}")
      end
    end

    private

    # Borrow from Rails, when not running Rails
    def self.camelize(term)
      string = term.to_s
      string = string.sub(/^[a-z\d]*/) { |match| match.capitalize }
      string.gsub!(/(?:_|(\/))([a-z\d]*)/i) { "#{$1}#{inflections.acronyms[$2] || $2.capitalize}" }
      string.gsub!('/'.freeze, '::'.freeze)
      string
    end

  end
end
