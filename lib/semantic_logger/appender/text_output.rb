module SemanticLogger
  module Appender
    # Writes the formatted text of log entries to an IO, such as a log file or standard output, for
    # the appenders that write to one (Appender::File and Appender::IO).
    #
    # An IO with an external encoding converts what it writes to that encoding: a file opened with an
    # `encoding:`, an IO that the application set one on, or one opened after Rails set
    # `Encoding.default_internal`, which gives it the external encoding UTF-8. Such an IO raises an
    # EncodingError for text that it cannot convert, such as binary text that holds bytes outside
    # ASCII, which a custom formatter can return, invalid UTF-8, or a character that its encoding
    # does not have, and the entry would be lost.
    module TextOutput
      # Writes the text to the IO, or, when the IO cannot convert it to its encoding, the text
      # converted first (see .writable_text). Only text that the IO refuses is converted.
      def self.write(io, text)
        io.write(text)
      rescue EncodingError
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
    end
  end
end
