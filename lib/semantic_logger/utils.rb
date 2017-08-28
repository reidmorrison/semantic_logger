module SemanticLogger::Utils

  def self.constantize_symbol(symbol, namespace = 'SemanticLogger::Appender')
    klass = "#{namespace}::#{camelize(symbol.to_s)}"
    begin
      if RUBY_VERSION.to_i >= 2
        Object.const_get(klass)
      else
        klass.split('::').inject(Object) { |o, name| o.const_get(name) }
      end
    rescue NameError
      raise(ArgumentError, "Could not convert symbol: #{symbol.inspect} to a class in: #{namespace}. Looking for: #{klass}")
    end
  end

  # Borrow from Rails, when not running Rails
  def self.camelize(term)
    string = term.to_s
    string = string.sub(/^[a-z\d]*/) { |match| match.capitalize }
    string.gsub!(/(?:_|(\/))([a-z\d]*)/i) { "#{$1}#{$2.capitalize}" }
    string.gsub!('/'.freeze, '::'.freeze)
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

  SELF_PATTERN = File.join('lib', 'semantic_logger')

  # Extract the backtrace leaving out the last few Semantic Logger lines.
  def self.cleanse_backtrace(stack = caller)
    while (first = stack.first) && first.include?(SELF_PATTERN)
      stack.shift
    end
    stack
  end

end
