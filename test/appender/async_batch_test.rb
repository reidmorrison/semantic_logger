require_relative '../test_helper'

module Appender
  class AsyncBatchTest < Minitest::Test
    describe SemanticLogger::Appender::Async do
      include InMemoryAppenderHelper

      let :appender do
        InMemoryBatchAppender.new
      end

      describe 'with default batch_size' do
        let :added_appender do
          SemanticLogger.add_appender(appender: appender, batch: true)
        end

        it 'uses the batch proxy' do
          assert_instance_of SemanticLogger::Appender::AsyncBatch, added_appender
        end

        it 'logs messages after a flush' do
          logger.info('hello world1')
          refute appender.message

          logger.info('hello world2')
          refute appender.message

          logger.info('hello world3')
          refute appender.message

          # Calls flush
          assert logs = log_message
          assert_equal 3, logs.size, logs
          assert_equal 'hello world1', logs[0].message
          assert_equal 'hello world2', logs[1].message
          assert_equal 'hello world3', logs[2].message
        end
      end

      # :batch_size, :batch_seconds
      describe 'with batch_size 1' do
        let :added_appender do
          SemanticLogger.add_appender(appender: appender, batch: true, batch_size: 1)
        end

        it 'uses the batch proxy' do
          assert_instance_of SemanticLogger::Appender::AsyncBatch, added_appender
        end

        it 'logs message immediately' do
          logger.info('hello world')

          assert logs = log_message
          assert_equal 1, logs.size, logs
          assert_equal 'hello world', logs.first.message
        end
      end
    end
  end
end
