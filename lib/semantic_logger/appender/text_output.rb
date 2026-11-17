module SemanticLogger
  module Appender
    # Writes the formatted text of log entries to an IO, such as a log file or standard output, for
    # the appenders that write to one (Appender::File and Appender::IO).
    #
    # An IO with an external encoding converts what it writes to that encoding, and raises an
    # EncodingError for text that it cannot convert, which would lose the entry. A file opened with an
    # `encoding:` such as UTF-16LE refuses invalid UTF-8, binary text that holds bytes outside ASCII,
    # which a custom formatter can return, and a character that its encoding does not have. An IO
    # that converts to UTF-8, such as one opened after Rails set `Encoding.default_internal`, refuses
    # only such binary text: it writes text tagged UTF-8 that holds invalid bytes as it is.
    module TextOutput
      # Writes the text to the IO, or, when the IO cannot convert it to its encoding, the text
      # converted first (see .writable_text). Only text that the IO refuses is converted.
      #
      # Only an IO that converts the whole text before it writes any of it is written to again (see
      # .converts_whole_text?). Another object that responds to #write, such as one that writes to
      # two IOs, could have written part of the text before it raised, which would then be written
      # twice, so its error is raised as before.
      #
      # Returns what IO#write returns: the number of bytes written, in the IO's encoding.
      def self.write(io, text)
        io.write(text)
      rescue EncodingError
        raise unless converts_whole_text?(io)

        io.write(writable_text(text, io))
      end

      # Returns [String] the text, converted to valid UTF-8 as the JSON formatters convert it (see
      # Utils.encode_utf8_string), and then, for an IO with an external encoding other than UTF-8,
      # converted to that encoding, with "?" (or U+FFFD for a Unicode encoding) in place of each
      # character that it does not have.
      def self.writable_text(text, io)
        text     = Utils.encode_utf8_string(text)
        encoding = io.external_encoding if io.respond_to?(:external_encoding)
        return text if encoding.nil? || encoding == Encoding::UTF_8 || encoding == Encoding::BINARY

        text.encode(encoding, invalid: :replace, undef: :replace)
      end
      private_class_method :writable_text

      # Whether the IO converts the whole text before it writes any of it: an ::IO, a Tempfile, which
      # writes with File#write, or a StringIO.
      def self.converts_whole_text?(io)
        io.is_a?(::IO) || (defined?(::Tempfile) && io.is_a?(::Tempfile)) ||
          (defined?(::StringIO) && io.is_a?(::StringIO))
      end
      private_class_method :converts_whole_text?

      # Returns [String] the formatted text of a log entry as the line that .write writes: a new
      # String of it followed by a line break. A new one, since the formatter's String can be one it
      # does not own, such as a custom formatter's log.message, the application's own, or frozen. It
      # keeps the text's encoding. An object that converts to a String implicitly (#to_str) is read
      # as that String, and anything else, such as nil, a Hash, or a Pathname, raises TypeError.
      # Interpolation would write any object, and tag US-ASCII text UTF-8.
      def self.line(text)
        string = String.try_convert(text)
        raise(TypeError, "Formatter returned a #{text.class}, not a String") unless string

        string + "\n" # rubocop:disable Style/StringConcatenation
      end
    end
  end
end
