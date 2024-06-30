module SemanticLogger
  module Formatters
    autoload :Base,         "semantic_logger/formatters/base"
    autoload :Color,        "semantic_logger/formatters/color"
    autoload :Default,      "semantic_logger/formatters/default"
    autoload :Json,         "semantic_logger/formatters/json"
    autoload :Raw,          "semantic_logger/formatters/raw"
    autoload :OneLine,      "semantic_logger/formatters/one_line"
    autoload :Signalfx,     "semantic_logger/formatters/signalfx"
    autoload :Syslog,       "semantic_logger/formatters/syslog"
    autoload :Fluentd,      "semantic_logger/formatters/fluentd"
    autoload :Logfmt,       "semantic_logger/formatters/logfmt"
    autoload :SyslogCee,    "semantic_logger/formatters/syslog_cee"
    autoload :NewRelicLogs, "semantic_logger/formatters/new_relic_logs"

    # Return formatter that responds to call.
    #
    # Supports formatter supplied as:
    # - Symbol
    # - Hash ( Symbol => { options })
    # - Instance of any of SemanticLogger::Formatters
    # - Proc
    # - Any object that responds to :call
    def self.factory(formatter)
      if formatter.is_a?(Symbol)
        SemanticLogger::Utils.constantize_symbol(formatter, "SemanticLogger::Formatters").new
      elsif formatter.is_a?(Hash) && formatter.size.positive?
        fmt, options = formatter.first
        SemanticLogger::Utils.constantize_symbol(fmt.to_sym, "SemanticLogger::Formatters").new(**options)
      elsif formatter.respond_to?(:call)
        formatter
      else
        raise(ArgumentError, "Unknown formatter: #{formatter.inspect}")
      end
    end
  end
end
