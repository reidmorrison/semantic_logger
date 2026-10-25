module SemanticLogger
  # Separates the detail that Ruby's Exception#detailed_message adds to an exception's message,
  # such as did_you_mean suggestions or error_highlight's source snippet, from the message itself.
  #
  # Internal: Log caches the result for each of its exceptions; see Log#exception_details.
  module ExceptionDetails
    # Ruby's own Exception#detailed_message: the message, decorated with the class name.
    DETAILED_MESSAGE = Exception.instance_method(:detailed_message)
    private_constant :DETAILED_MESSAGE

    # Returns [String] the detail that #detailed_message adds to the exception's message, without
    # the class name that Ruby also adds, or nil when there is none or it cannot be separated.
    #
    # Never raises, so that an exception's own #detailed_message cannot stop a log entry being
    # written.
    def self.extract(exception, source: false)
      detailed = full_detailed_message(exception, source)
      return unless detailed

      base = DETAILED_MESSAGE.bind_call(exception, highlight: false)
      # An override that does not build on Ruby's message cannot be separated from it.
      return unless detailed.is_a?(String) && detailed.start_with?(base)

      details = detailed.delete_prefix(base).sub(/\A\n+/, "").rstrip
      details unless details.empty?
    rescue StandardError
      nil
    end

    # Returns [String] the exception's #detailed_message, with or without error_highlight's
    # source snippet, or nil when the snippet cannot be left out.
    def self.full_detailed_message(exception, source)
      exception.detailed_message(highlight: false, error_highlight: source)
    rescue ArgumentError
      # An override of #detailed_message that does not accept extra keyword arguments. Calling it
      # without `error_highlight: false` lets error_highlight add its source snippet, so only do so
      # when the snippet was asked for, or error_highlight does not decorate this exception.
      return if !source && error_highlighted?(exception)

      exception.detailed_message(highlight: false)
    end
    private_class_method :full_detailed_message

    # Whether error_highlight adds a source snippet to this exception's #detailed_message.
    def self.error_highlighted?(exception)
      defined?(ErrorHighlight::CoreExt) && exception.is_a?(ErrorHighlight::CoreExt)
    end
    private_class_method :error_highlighted?
  end
end
