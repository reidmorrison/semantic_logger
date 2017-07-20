require_relative '../test_helper'

module SemanticLogger
  module Formatters
    class DefaultTest < Minitest::Test
      describe Default do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          log      = SemanticLogger::Log.new('DefaultTest', level)
          log.time = log_time
          log
        end

        let(:set_exception) do
          begin
            raise 'Oh no'
          rescue Exception => exc
            log.exception = exc
          end
        end

        let(:formatter) do
          formatter = SemanticLogger::Formatters::OneLine.new
          # Does not use the logger instance for formatting purposes
          formatter.call(log, nil)
          formatter
        end

        describe 'message' do
          it 'logs message' do
            log.message = "Hello \nWorld\n"
            assert_equal "-- Hello World", formatter.message
          end

          it 'skips empty message' do
            refute formatter.message
          end
        end

        describe 'exception' do
          it 'logs exception' do
            set_exception
            assert_equal '-- Exception: RuntimeError: Oh no', formatter.exception
          end

          it 'skips nil exception' do
            refute formatter.exception
          end
        end

      end
    end
  end
end
