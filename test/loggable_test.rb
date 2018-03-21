require_relative 'test_helper'
require 'stringio'

class TestAttribute
  include SemanticLogger::Loggable
end

# Unit Test for SemanticLogger::Appender::File
#
class AppenderFileTest < Minitest::Test
  module Perform
    def perform
      logger.info 'perform'
    end
  end

  class Base
    include SemanticLogger::Loggable
    include Perform
  end

  module Process
    def process
      logger.info 'process'
    end
  end

  class Subclass < Base
    include Process
  end

  describe SemanticLogger::Loggable do
    describe 'inheritance' do
      it 'should give child classes their own logger' do
        assert_equal Subclass.name, Subclass.logger.name
        assert_equal Base.name, Base.logger.name
        assert_equal Subclass.name, Subclass.logger.name
        child_logger = Subclass.logger
        refute_equal child_logger, Base.logger
        assert_equal child_logger.object_id, Subclass.logger.object_id
      end

      it 'should give child objects their own logger' do
        subclass = Subclass.new
        base     = Base.new
        assert_equal subclass.class.name, subclass.logger.name
        assert_equal base.class.name, base.logger.name
        assert_equal subclass.class.name, subclass.logger.name
        child_logger = subclass.logger
        refute_equal child_logger, base.logger
        assert_equal child_logger.object_id, subclass.logger.object_id
      end

      it 'should allow mixins to call parent logger' do
        base = Base.new
        base.perform
        called = false
        Base.logger.stub(:info, ->(description) { called = true if description == 'perform' }) do
          base.perform
        end
        assert called, 'Did not call the correct logger'
      end

      it 'should allow child mixins to call parent logger' do
        subclass = Subclass.new
        subclass.process
        called = false
        Subclass.logger.stub(:info, ->(description) { called = true if description == 'process' }) do
          subclass.process
        end
        assert called, 'Did not call the correct logger'
      end
    end

    describe 'logger' do
      include InMemoryAppenderHelper

      describe 'for each log level' do
        # Ensure that any log level can be logged
        SemanticLogger::LEVELS.each do |level|
          it "logs #{level} information with class attribute" do
            TestAttribute.logger.send(level, "hello #{level}", payload)

            assert log = log_message
            assert_equal "hello #{level}", log.message
            assert_equal level, log.level
            assert_equal 'TestAttribute', log.name
            assert_equal payload, log.payload
          end

          it "log #{level} information with instance attribute" do
            TestAttribute.new.logger.send(level, "hello #{level}", payload)
            assert log = log_message
            assert_equal "hello #{level}", log.message
            assert_equal level, log.level
            assert_equal 'TestAttribute', log.name
            assert_equal payload, log.payload
          end
        end
      end
    end
  end
end
