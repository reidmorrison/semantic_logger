require_relative "test_helper"

class InternalLoggerCopyTest < Minitest::Test
  # Answers the internal logger to copy, which a test replaces.
  Source = Struct.new(:logger)

  describe SemanticLogger::InternalLoggerCopy do
    let(:first) { SemanticLogger::Appender::IO.new(StringIO.new) }
    let(:source) { Source.new(first) }
    let(:copy) { SemanticLogger::InternalLoggerCopy.new("MyAppender", source) }

    it "is a copy of the internal logger named after whatever reports to it" do
      refute_same first, copy.logger
      assert_kind_of SemanticLogger::Appender::IO, copy.logger
      assert_equal "MyAppender", copy.logger.name
    end

    it "leaves the name of the internal logger as it is" do
      name = first.name
      copy.logger

      assert_equal name, first.name
    end

    it "returns the same copy while the internal logger is not replaced" do
      assert_same copy.logger, copy.logger
    end

    describe "#copy?" do
      it "is true for the copy that it returns now" do
        assert copy.copy?(copy.logger)
      end

      it "is false for the internal logger, any other logger, and nil" do
        copy.logger

        refute copy.copy?(first)
        refute copy.copy?(SemanticLogger::Appender::IO.new(StringIO.new))
        refute copy.copy?(nil)
      end

      it "is false before it has made a copy" do
        refute copy.copy?(nil)
      end
    end

    it "copies the internal logger that replaced it" do
      output       = StringIO.new
      before       = copy.logger
      source.logger = SemanticLogger::Appender::IO.new(output)

      refute_same before, copy.logger
      assert_equal "MyAppender", copy.logger.name
      copy.logger.warn("Could not connect")

      assert_includes output.string, "Could not connect"
    end
  end
end
