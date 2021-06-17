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

    # Extract the backtrace stripping off the leading semantic logger entries.
    # Leaves all other system and gem path entries in place.
    def self.extract_backtrace(stack = caller)
      while (first = stack.first) && extract_path?(first)
        stack.shift
      end
      stack
    end

    def self.extract_paths
      @extract_paths ||= %w[lib/semantic_logger lib/rails_semantic_logger]
    end

    # Whether this path should be excluded from any cleansed backtrace
    def self.extract_path?(path)
      extract_paths.any? { |exclude| path.include?(exclude) }
    end

    # Try to strip everything off of the supplied backtrace, until the first application stack entry is at the top.
    # For example all leading gem paths and built-in ruby code paths are removed from the top.
    # Once the first application entry is found, the remaining stack is returned.
    def self.strip_backtrace(stack = caller)
      while (first = stack.first) && (strip_path?(first) || extract_path?(first))
        stack.shift
      end
      stack
    end

    # Paths to exclude in the stripped backtrace
    # Includes Gems and built-in Ruby code paths
    def self.strip_paths
      @strip_paths ||=
        begin
          paths = Gem.path | [Gem.default_dir]
          paths << RbConfig::CONFIG["rubylibdir"]
          paths
        end
    end

    # Whether this path should be excluded from any cleansed backtrace
    def self.strip_path?(path)
      strip_paths.any? { |exclude| path.start_with?(exclude) }
    end
  end
end
