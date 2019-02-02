module SemanticLogger
  class Appenders < Concurrent::Array
    def add(options, deprecated_level = nil, &block)
      options  = options.is_a?(Hash) ? options.dup : convert_old_appender_args(options, deprecated_level)
      appender = SemanticLogger::Appender.factory(options, &block)
      self << appender
      appender
    end

    private

    # Backward compatibility
    def convert_old_appender_args(appender, level)
      options         = {}
      options[:level] = level if level

      if appender.is_a?(String)
        options[:file_name] = appender
      elsif appender.is_a?(IO)
        options[:io] = appender
      elsif appender.is_a?(Symbol) || appender.is_a?(Subscriber)
        options[:appender] = appender
      else
        options[:logger] = appender
      end
      warn "[DEPRECATED] SemanticLogger.add_appender parameters have changed. Please use: #{options.inspect}"
      options
    end
  end
end
