require_relative "test_helper"

class AppenderTest < Minitest::Test
  describe SemanticLogger::Appender do
    # #build is a private class method reached publicly via SemanticLogger.add_appender.
    def build(**args, &block)
      SemanticLogger::Appender.send(:build, **args, &block)
    end

    describe ".build" do
      describe "with :appender" do
        it "raises when not a Symbol or Subscriber" do
          error = assert_raises ArgumentError do
            build(appender: "not valid")
          end
          assert_includes error.message, "Parameter :appender"
        end
      end

      describe "with :metric" do
        it "builds a metric subscriber from a Symbol" do
          appender = build(metric: :statsd)

          assert_kind_of SemanticLogger::Metric::Statsd, appender
        end

        it "returns the supplied metric Subscriber instance" do
          metric   = SemanticLogger::Metric::Statsd.new
          appender = build(metric: metric)

          assert_same metric, appender
        end

        it "raises when not a Symbol or Subscriber" do
          error = assert_raises ArgumentError do
            build(metric: "not valid")
          end
          assert_includes error.message, "Parameter :metric"
        end
      end

      it "raises when no destination option is supplied" do
        error = assert_raises ArgumentError do
          build(level: :info)
        end
        assert_includes error.message, ":io, :file_name, :appender, :metric, or :logger"
      end
    end
  end
end
