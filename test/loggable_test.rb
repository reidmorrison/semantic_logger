require_relative "test_helper"
require "stringio"

class AppenderFileTest < Minitest::Test
  module Perform
    def perform
      logger.info "perform"
    end
  end

  class Base
    include SemanticLogger::Loggable
    include Perform
  end

  module Process
    def process
      logger.info "process"
    end
  end

  class Subclass < Base
    include Process
  end

  class TestAttribute
    include SemanticLogger::Loggable
  end

  class Measured
    include SemanticLogger::Loggable

    def double(value)
      value * 2
    end
    logger_measure_method :double

    def explode
      raise "boom"
    end
    logger_measure_method :explode, level: :error

    def quick
      :done
    end
    logger_measure_method :quick, min_duration: 60_000
  end

  describe SemanticLogger::Loggable do
    describe "inheritance" do
      it "should give child classes their own logger" do
        assert_equal Subclass.name, Subclass.logger.name
        assert_equal Base.name, Base.logger.name
        assert_equal Subclass.name, Subclass.logger.name
        child_logger = Subclass.logger

        refute_equal child_logger, Base.logger
        assert_same child_logger, Subclass.logger
      end

      it "should give child objects their own logger" do
        subclass = Subclass.new
        base     = Base.new

        assert_equal subclass.class.name, subclass.logger.name
        assert_equal base.class.name, base.logger.name
        assert_equal subclass.class.name, subclass.logger.name
        child_logger = subclass.logger

        refute_equal child_logger, base.logger
        assert_same child_logger, subclass.logger
      end

      it "should allow mixins to call parent logger" do
        base = Base.new
        base.perform
        called = false
        Base.logger.stub(:info, ->(description) { called = true if description == "perform" }) do
          base.perform
        end

        assert called, "Did not call the correct logger"
      end

      it "should allow child mixins to call parent logger" do
        subclass = Subclass.new
        subclass.process
        called = false
        Subclass.logger.stub(:info, ->(description) { called = true if description == "process" }) do
          subclass.process
        end

        assert called, "Did not call the correct logger"
      end
    end

    describe "sample class" do
      it "has class level logger" do
        TestAttribute.logger.is_a?(SemanticLogger::Logger)
      end

      it "has instance level logger" do
        TestAttribute.new.logger.is_a?(SemanticLogger::Logger)
      end
    end

    describe "#logger=" do
      it "overrides the class level logger" do
        custom   = SemanticLogger::Test::CaptureLogEvents.new
        original = TestAttribute.logger
        begin
          TestAttribute.logger = custom

          assert_same custom, TestAttribute.logger
          assert_same custom, TestAttribute.new.logger
        ensure
          TestAttribute.logger = original
        end
      end

      it "overrides an individual instance logger" do
        custom   = SemanticLogger::Test::CaptureLogEvents.new
        instance = TestAttribute.new
        instance.logger = custom

        assert_same custom, instance.logger
        refute_same custom, TestAttribute.new.logger
      end
    end

    describe "#logger_measure_method" do
      let(:capture) { SemanticLogger::Test::CaptureLogEvents.new }

      before do
        Measured.logger = capture
      end

      after do
        Measured.logger = nil
      end

      it "logs the method duration and returns the result" do
        assert_equal 8, Measured.new.double(4)

        assert log = capture.events.first
        assert_equal "#double", log.message
        assert_equal :info, log.level
        assert_equal "#{Measured.name}/double", log.metric
        refute_nil log.duration
      end

      it "logs and re-raises when the method raises" do
        assert_raises(RuntimeError) { Measured.new.explode }

        assert log = capture.events.first
        assert_equal :error, log.level
        assert_match(/Exception: RuntimeError: boom/, log.message)
      end

      it "does not log when the duration is below min_duration" do
        assert_equal :done, Measured.new.quick
        assert_empty capture.events
      end

      it "runs the method without logging when the level is not met" do
        capture.level = :fatal

        assert_equal 8, Measured.new.double(4)
        assert_empty capture.events
      end

      describe "arguments written into the generated method" do
        let(:klass) do
          Class.new do
            include SemanticLogger::Loggable

            def self.name = "MeasuredArguments"

            def run = :ran
          end
        end

        it "rejects a min_duration that is not a number, instead of evaluating it" do
          assert_raises(ArgumentError) do
            klass.logger_measure_method(:run, min_duration: "(raise('injected code ran'); 0.0)")
          end

          # Had the code been written into the method, calling it would raise.
          assert_equal :ran, klass.new.run
        end

        it "rejects a method name that is not an identifier" do
          assert_raises(ArgumentError) do
            klass.logger_measure_method(:"run(*); raise('injected code ran'); def x")
          end
        end

        it "rejects a method name that would write code into the generated method" do
          ["run; raise('injected code ran')", "foo; system('x')", "run\nraise('x')", "@run", "@@run", "$run", "",
           "Kernel.run", "Kernel::run"].each do |name|
            assert_raises(ArgumentError, name.inspect) { klass.logger_measure_method(name) }
          end
          assert_equal :ran, klass.new.run
        end

        it "measures every kind of valid method name" do
          operators = Class.new do
            include SemanticLogger::Loggable

            def self.name = "MeasuredOperators"

            def [](key) = [:get, key]

            def []=(key, value)
              [:set, key, value]
            end

            def ==(other) = [:equal, other]
            def +(other) = [:plus, other]
            def -@ = :negated
            def valid? = true
            def save! = :saved

            def value=(value)
              [:value, value]
            end

            define_method("café") { :coffee }
          end
          names = %i[[] []= == + -@ valid? save! value=] + ["café"]

          names.each { |name| assert operators.logger_measure_method(name), "name: #{name.inspect}" }
          operators.logger = capture
          instance = operators.new

          assert_equal [:get, 1], instance[1]
          assert_equal [:set, 1, 2], instance.public_send(:[]=, 1, 2)
          assert_equal [:equal, 1], instance.public_send(:==, 1)
          assert_equal [:plus, 1], instance + 1
          assert_equal :negated, -instance
          assert_predicate instance, :valid?
          assert_equal :saved, instance.save!
          assert_equal [:value, 3], instance.public_send(:value=, 3)
          assert_equal :coffee, instance.public_send("café")
          assert_equal names.map { |name| "##{name}" }, capture.events.map(&:message)
        ensure
          operators.logger = nil
        end

        it "rejects a min_duration that is not a finite number" do
          ["1e400", "-1e400", Float::INFINITY, Float::NAN, nil, true, "", "abc", Object.new].each do |value|
            assert_raises(ArgumentError, value.inspect) { klass.logger_measure_method(:run, min_duration: value) }
          end
          assert_equal :ran, klass.new.run
        end

        it "logs a metric only event when the message is nil" do
          assert klass.logger_measure_method(:run, message: nil, metric: "Klass/run")
          klass.logger = capture

          assert_equal :ran, klass.new.run
          assert log = capture.events.first
          assert_nil log.message
          assert_equal "Klass/run", log.metric
          assert_predicate log, :metric_only?
        ensure
          klass.logger = nil
        end

        it "rejects an invalid log_exception value" do
          assert_raises(ArgumentError) { klass.logger_measure_method(:run, log_exception: "full") }
        end

        it "accepts a numeric String min_duration, a String message, and String levels" do
          assert klass.logger_measure_method(:run, min_duration: "0", message: "Running", level: "info",
                                                   on_exception_level: "error")
          klass.logger = capture

          assert_equal :ran, klass.new.run
          assert_equal "Running", capture.events.first.message
        ensure
          klass.logger = nil
        end
      end
    end
  end
end
