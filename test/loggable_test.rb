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

  module LoggableModule
    include SemanticLogger::Loggable

    def work
      logger.info "work"
    end
  end

  class ModuleHost
    include LoggableModule
  end

  class LoggableModuleHost < Base
    include LoggableModule
  end

  class ClassLoggerModuleHost
    include LoggableModule

    def self.logger
      @logger ||= SemanticLogger::Test::CaptureLogEvents.new
    end
  end

  class ExtendedModuleHost
    extend LoggableModule
  end

  class OwnLoggerModuleHost
    include LoggableModule

    def logger
      @logger ||= SemanticLogger::Test::CaptureLogEvents.new
    end
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

    describe "included into a module" do
      it "gives the module a class level logger named after it" do
        assert_equal LoggableModule.name, LoggableModule.logger.name
      end

      it "gives instances of a class without Loggable a logger named after that class" do
        host = ModuleHost.new

        assert_equal ModuleHost.name, host.logger.name
        assert_same host.logger, host.logger
      end

      it "logs from module methods called on a class without Loggable" do
        host    = ModuleHost.new
        capture = SemanticLogger::Test::CaptureLogEvents.new
        host.logger = capture
        host.work

        assert_equal "work", capture.events.first.message
      end

      it "adds no class level logger to a class without Loggable" do
        refute_respond_to ModuleHost, :logger
      end

      it "uses the class level logger of a class with Loggable" do
        host = LoggableModuleHost.new

        assert_same LoggableModuleHost.logger, host.logger
      end

      it "uses the class level logger of a class without Loggable" do
        host = ClassLoggerModuleHost.new
        host.work

        assert_same ClassLoggerModuleHost.logger, host.logger
        assert_equal "work", ClassLoggerModuleHost.logger.events.first.message
      end

      it "gives a class that extends the module a logger named after that class" do
        assert_equal ExtendedModuleHost.name, ExtendedModuleHost.logger.name
      end

      it "keeps the logger a class defines itself" do
        host = OwnLoggerModuleHost.new
        host.work

        assert_equal "work", host.logger.events.first.message
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
  end
end
