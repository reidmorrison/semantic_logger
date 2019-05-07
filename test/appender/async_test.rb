require_relative '../test_helper'

module Appender
  class AsyncTest < Minitest::Test
    describe SemanticLogger::Appender::Async do
      include InMemoryAppenderHelper

      describe 'with capped queue' do
        let :added_appender do
          SemanticLogger.add_appender(appender: appender, async: true)
        end

        it 'uses the async proxy' do
          assert_instance_of SemanticLogger::Appender::Async, added_appender
        end

        it 'logs message immediately' do
          logger.info('hello world')

          assert log = log_message
          assert_equal 'hello world', log.message
        end

        it 'uses an capped queue' do
          assert_instance_of SizedQueue, added_appender.queue
        end
      end

      describe 'with uncapped queue' do
        let :added_appender do
          SemanticLogger.add_appender(appender: appender, async: true, max_queue_size: -1)
        end

        it 'uses the async proxy' do
          assert_instance_of SemanticLogger::Appender::Async, added_appender
        end

        it 'uses an uncapped queue' do
          assert_instance_of Queue, added_appender.queue
        end
      end
    end
  end
end
