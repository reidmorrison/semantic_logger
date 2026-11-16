# Exceptions whose #message raises, for the tests of how a logged exception's message is read.
module ExceptionFixtures
  # Its #message raises, as one that reads a record that is nil can.
  class BrokenMessageError < StandardError
    def message = raise(NoMethodError, "undefined method 'id' for nil")
  end

  # Its #message raises NotImplementedError, as an abstract one's can: a ScriptError, not a
  # StandardError.
  class AbstractMessageError < StandardError
    def message = raise(NotImplementedError, "#{self.class.name} must define #message")
  end
end
