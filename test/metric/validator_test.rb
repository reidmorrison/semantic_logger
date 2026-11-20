require_relative "../test_helper"
require_relative "../signal_trap_helper"

module Metric
  class ValidatorTest < Minitest::Test
    describe SemanticLogger::Metric::Validator do
      include SignalTrapHelper

      let(:warnings_limit) { SemanticLogger::Metric::Validator::WARNINGS_LIMIT }
      let(:validator) { SemanticLogger::Metric::Validator.new(warnings_limit: warnings_limit) }
      let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }
      let(:processor) { Struct.new(:logger).new(internal_logger) }

      # Returns what #accept returns, with the processor's internal logger captured.
      def accept(kind, name, value, dimensions = nil)
        SemanticLogger::Logger.stub(:processor, processor) { validator.accept(kind, name, value, dimensions) }
      end

      def warnings
        internal_logger.events.map(&:message)
      end

      it "accepts a String name and a Numeric value" do
        assert_equal "users.signup", accept(:counter, "users.signup", 1)
        assert_equal "users.signup", accept(:counter, "users.signup", 2.5, {plan: "free"})
        assert_equal "order.total", accept(:histogram, "order.total", Rational(1, 3))
        assert_empty warnings
      end

      it "returns a Symbol name as a String" do
        assert_equal "users.signup", accept(:counter, :"users.signup", 1)
      end

      it "accepts zero for a counter, and a negative value for a histogram" do
        assert_equal "users.signup", accept(:counter, "users.signup", 0)
        assert_equal "temperature", accept(:histogram, "temperature", -12.5)
        assert_empty warnings
      end

      it "drops a negative counter amount, warning once per name" do
        assert_nil accept(:counter, "users.signup", -1)
        assert_nil accept(:counter, "users.signup", -2)
        assert_nil accept(:counter, "users.left", -1.5)

        assert_equal 2, warnings.size
        assert_includes warnings.first, 'Dropped counter "users.signup"'
        assert_includes warnings.first, "its amount -1 is negative"
        assert_includes warnings.last, '"users.left"'
        assert_equal [:warn], internal_logger.events.map(&:level).uniq
      end

      it "drops a value that is not a finite real Numeric, for every kind" do
        [Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(1, 2), "1", nil].each do |value|
          assert_nil accept(:counter, "count", value)
          assert_nil accept(:histogram, "size", value)
        end

        assert_equal 2, warnings.size
        assert_includes warnings.first, "its value NaN is not a finite real Numeric"
      end

      it "drops a name that is not a non-empty String or Symbol, warning once per class" do
        assert_nil accept(:counter, nil, 1)
        assert_nil accept(:counter, 42, 1)
        assert_nil accept(:counter, 43, 1)
        assert_nil accept(:counter, "", 1)
        assert_nil accept(:counter, :"", 1)

        assert_equal 4, warnings.size
        assert_includes warnings.first, "its name must be a non-empty String or Symbol"
      end

      it "drops dimensions that are not a Hash" do
        assert_nil accept(:counter, "users.signup", 1, [:plan, "free"])

        assert_includes warnings.first, "its dimensions [:plan, \"free\"] are not a Hash"
      end

      it "warns about each problem of a name once" do
        accept(:counter, "users.signup", -1)
        accept(:counter, "users.signup", Float::NAN)
        accept(:counter, "users.signup", -1)

        assert_equal 2, warnings.size
      end

      describe "with a warnings limit" do
        let(:warnings_limit) { 2 }

        it "stops warning once it has warned that many times" do
          %w[a b c].each { |name| assert_nil accept(:counter, name, -1) }

          assert_equal 2, warnings.size
        end
      end

      it "drops without a warning, and without raising, in a signal trap" do
        result = SemanticLogger::Logger.stub(:processor, processor) do
          in_signal_trap { validator.accept(:counter, "users.signup", -1, nil) }
        end

        assert_nil result
        assert_empty warnings
      end

      it "never raises when the internal logger does" do
        failing = Object.new
        failing.define_singleton_method(:warn) { |*| raise "boom" }
        processor.logger = failing

        assert_nil accept(:counter, "users.signup", -1)
      end
    end
  end
end
