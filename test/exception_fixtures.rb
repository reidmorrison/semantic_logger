# Exceptions whose #message raises, or whose class names itself, for the tests of how a logged
# exception is named and its message read.
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

  # Its class names itself otherwise, in each way that Ruby code asks a class for its name.
  class OtherwiseNamedError < StandardError
    def self.name = "PaymentError"

    def self.to_s = name

    def self.inspect = name
  end

  # Its class raises when asked for its name, in each way that Ruby code asks, as one that reads a
  # setting that is nil can.
  class UnnameableError < StandardError
    def self.name = raise(NoMethodError, "undefined method 'prefix' for nil")

    def self.to_s = name

    def self.inspect = name
  end

  # Its class is named outside ASCII by the constant it is assigned to, "FehlÄr", in ISO-8859-1: Ruby
  # names a class in its constant's encoding.
  ISO_8859_1_NAMED_ERROR = const_set("Fehl\xC4r".dup.force_encoding(Encoding::ISO_8859_1), Class.new(StandardError))
end
