module SemanticLogger
  module Formatters
    # @formatter:off
    autoload :Base,             'semantic_logger/formatters/base'
    autoload :Color,            'semantic_logger/formatters/color'
    autoload :Default,          'semantic_logger/formatters/default'
    autoload :Json,             'semantic_logger/formatters/json'
    autoload :Raw,              'semantic_logger/formatters/raw'
    autoload :Signalfx,         'semantic_logger/formatters/signalfx'
    autoload :Syslog,           'semantic_logger/formatters/syslog'
    # @formatter:on

    # Return formatter that responds to call.
    #
    # Supports formatter supplied as:
    # - Symbol
    # - Hash ( Symbol => { options })
    # - Instance of any of SemanticLogger::Formatters
    # - Proc
    # - Any object that responds to :call
    # - If none of the above apply, then the supplied block is returned as the formatter.
    # - Otherwise an instance of the default formatter is returned.
    def self.factory(formatter, &block)
      case
      when formatter.is_a?(Symbol)
        SemanticLogger::Utils.constantize_symbol(formatter, 'SemanticLogger::Formatters').new
      when formatter.is_a?(Hash) && formatter.size > 0
        fmt, options = formatter.first
        SemanticLogger::Utils.constantize_symbol(fmt.to_sym, 'SemanticLogger::Formatters').new(options)
      when formatter.respond_to?(:call)
        formatter
      when block
        block
      end
    end

  end
end
