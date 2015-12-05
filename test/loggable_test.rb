require_relative 'test_helper'
require 'stringio'

class TestAttribute
  include SemanticLogger::Loggable
end

# Unit Test for SemanticLogger::Appender::File
#
class AppenderFileTest < Minitest::Test
  class Base
    include SemanticLogger::Loggable
  end

  class Subclass < Base
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
        base = Base.new
        assert_equal subclass.class.name, subclass.logger.name
        assert_equal base.class.name, base.logger.name
        assert_equal subclass.class.name, subclass.logger.name
        child_logger = subclass.logger
        refute_equal child_logger, base.logger
        assert_equal child_logger.object_id, subclass.logger.object_id
      end
    end

    describe 'logger' do
      before do
        @time                        = Time.new
        @io                          = StringIO.new
        @appender                    = SemanticLogger::Appender::File.new(@io)
        SemanticLogger.default_level = :trace
        @mock_logger                 = MockLogger.new
        @appender                    = SemanticLogger.add_appender(@mock_logger)
        @hash                        = {session_id: 'HSSKLEU@JDK767', tracking_number: 12345}
        @hash_str                    = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
        @thread_name                 = Thread.current.name
      end

      after do
        SemanticLogger.remove_appender(@appender)
      end

      describe 'for each log level' do
        # Ensure that any log level can be logged
        SemanticLogger::LEVELS.each do |level|
          it "log #{level} information with class attribute" do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              SemanticLogger.stub(:appenders, [@appender]) do
                TestAttribute.logger.send(level, "hello #{level}", @hash)
                SemanticLogger.flush
                assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:#{@thread_name} loggable_test.rb:\d+\] TestAttribute -- hello #{level} -- #{@hash_str}/, @mock_logger.message
              end
            end
          end

          it "log #{level} information with instance attribute" do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              SemanticLogger.stub(:appenders, [@appender]) do
                TestAttribute.new.logger.send(level, "hello #{level}", @hash)
                SemanticLogger.flush
                assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:#{@thread_name} loggable_test.rb:\d+\] TestAttribute -- hello #{level} -- #{@hash_str}/, @mock_logger.message
              end
            end
          end
        end
      end
    end

  end
end
