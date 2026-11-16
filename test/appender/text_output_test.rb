require_relative "../test_helper"
require "stringio"
require "tmpdir"
require "tempfile"

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

      # An object that is not an IO, which refuses the text, but would take it written again.
      let(:refusing_io) do
        io = Object.new
        def io.written = (@written ||= [])

        def io.write(text)
          raise(Encoding::CompatibilityError, "refused") if (@writes = @writes.to_i + 1) == 1

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

      it "writes text to a StringIO that holds text in an encoding that cannot take it" do
        io = StringIO.new("é\n".encode(Encoding::ISO_8859_1))
        io.seek(0, ::IO::SEEK_END)

        SemanticLogger::Appender::TextOutput.write(io, "☕\n")

        assert_equal "é\n?\n".encode(Encoding::ISO_8859_1), io.string
      end

      it "does not write again to another object, which could have written part of the text" do
        assert_raises(Encoding::CompatibilityError) { SemanticLogger::Appender::TextOutput.write(refusing_io, "Café".b) }
        assert_empty refusing_io.written
      end

      it "returns the number of bytes written in the IO's encoding" do
        Dir.mktmpdir do |dir|
          File.open(File.join(dir, "test.log"), "a", encoding: "UTF-16LE") do |file|
            assert_equal 6, SemanticLogger::Appender::TextOutput.write(file, "ab\n")
            assert_equal 4, SemanticLogger::Appender::TextOutput.write(file, (+"a\xFF\n").force_encoding(Encoding::UTF_8))
          end
        end
      end

      it "raises when the IO refuses the converted text too" do
        io = StringIO.new
        def io.writes = (@writes ||= 0)

        def io.write(_text)
          @writes = writes + 1
          raise(Encoding::CompatibilityError, "refused")
        end

        assert_raises(Encoding::CompatibilityError) { SemanticLogger::Appender::TextOutput.write(io, "Café".b) }
        assert_equal 2, io.writes
      end

      # A Tempfile delegates to a File, so it is not an IO itself.
      it "writes binary text that holds UTF-8 to a Tempfile that converts to UTF-8" do
        file = Tempfile.new("text_output")
        file.set_encoding(Encoding::UTF_8)
        SemanticLogger::Appender::TextOutput.write(file, "Café\n".b)
        file.flush

        assert_equal "Café\n".b, File.binread(file.path)
      ensure
        file&.close!
      end
    end
  end
end
