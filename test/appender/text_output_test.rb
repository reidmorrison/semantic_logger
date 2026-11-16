require_relative "../test_helper"
require "stringio"
require "tmpdir"

module Appender
  class TextOutputTest < Minitest::Test
    describe SemanticLogger::Appender::TextOutput do
      # Writes the text to a file opened with the encoding, and returns the bytes written.
      def written(text, encoding)
        Dir.mktmpdir do |dir|
          path = File.join(dir, "test.log")
          File.open(path, "a", encoding: encoding) { |file| SemanticLogger::Appender::TextOutput.write(file, text) }
          File.binread(path)
        end
      end

      # An IO without an external encoding that refuses the first text written to it.
      let(:refusing_io) do
        io = Object.new
        def io.written = (@written ||= [])

        def io.write(text)
          unless @refused
            @refused = true
            raise(Encoding::CompatibilityError, "refused")
          end
          written << text
        end
        io
      end

      it "writes text that the IO takes as it is" do
        io   = StringIO.new
        text = "Café ☕\n"

        SemanticLogger::Appender::TextOutput.write(io, text)

        assert_equal "Café ☕\n", io.string
      end

      it "writes binary text that holds UTF-8 to an IO that converts to UTF-8" do
        assert_equal "Café ☕\n".b, written("Café ☕\n".b, "UTF-8")
      end

      it "writes invalid UTF-8 to an IO that converts to UTF-16, without its invalid bytes" do
        text = (+"bad \xFF byte\n").force_encoding(Encoding::UTF_8)

        assert_equal "bad  byte\n".encode(Encoding::UTF_16LE).b, written(text, "UTF-16LE")
      end

      it "writes a character that the IO's encoding does not have as ?" do
        assert_equal "Café ?\n".encode(Encoding::ISO_8859_1).b, written("Café ☕\n", "ISO-8859-1")
      end

      it "writes text to a StringIO that holds text in an incompatible encoding" do
        io = StringIO.new
        SemanticLogger::Appender::TextOutput.write(io, "☕\n")

        SemanticLogger::Appender::TextOutput.write(io, "Café\n".encode(Encoding::ISO_8859_1))

        assert_equal "☕\nCafé\n", io.string
      end

      it "writes the text as valid UTF-8 to an IO without an external encoding" do
        SemanticLogger::Appender::TextOutput.write(refusing_io, "Café \xFF☕".b)

        assert_equal ["Café ☕"], refusing_io.written
        assert_equal Encoding::UTF_8, refusing_io.written.first.encoding
      end

      it "raises when the IO refuses the converted text too" do
        io = Object.new
        def io.write(_text) = raise(Encoding::CompatibilityError, "refused")

        assert_raises(Encoding::CompatibilityError) { SemanticLogger::Appender::TextOutput.write(io, "Café".b) }
      end
    end
  end
end
