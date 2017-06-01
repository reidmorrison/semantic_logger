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
      raise(ArgumentError, "Could not convert symbol: #{symbol} to a class in: #{namespace}. Looking for: #{klass}")
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

end
