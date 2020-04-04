module SemanticLogger
  # Internal-use only utility functions for Semantic Logger.
  # Not intended for public use.
  module Utils
    def self.constantize_symbol(symbol, namespace = "SemanticLogger::Appender")
      klass = "#{namespace}::#{camelize(symbol.to_s)}"
      begin
        Object.const_get(klass)
      rescue NameError
        raise(ArgumentError, "Could not convert symbol: #{symbol.inspect} to a class in: #{namespace}. Looking for: #{klass}")
      end
    end

    # Borrow from Rails, when not running Rails
    def self.camelize(term)
      string = term.to_s
      string = string.sub(/^[a-z\d]*/, &:capitalize)
      string.gsub!(%r{(?:_|(/))([a-z\d]*)}i) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).capitalize}" }
      string.gsub!("/".freeze, "::".freeze)
      string
    end

    # Returns the visibility for an instance method
    def self.method_visibility(mod, method_name)
      method_name = method_name.to_sym
      if mod.instance_methods.include?(method_name)
        :public
      elsif mod.private_instance_methods.include?(method_name)
        :private
      elsif mod.protected_instance_methods.include?(method_name)
        :protected
      end
    end

    SELF_PATTERN = File.join("lib", "semantic_logger")

    # Extract the backtrace leaving out the last few Semantic Logger lines.
    def self.extract_backtrace(stack = caller)
      while (first = stack.first) && first.include?(SELF_PATTERN)
        stack.shift
      end
      stack
    end

    # Strips off all gems and built-in ruby code paths from the top of the stack until application code is found.
    def self.strip_backtrace(stack = caller)
      while (first = stack.first) && system_path?(first)
        stack.shift
      end
      stack
    end

    GEM_ROOT = File.expand_path("../../..", __dir__) + "/"

    def self.system_path?(path)
      path.start_with?(GEM_ROOT) ||
        path.start_with?(RbConfig::CONFIG["rubylibdir"])
    end
  end
end
