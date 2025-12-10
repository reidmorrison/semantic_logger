require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class JsonTest < Minitest::Test
      describe Json do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          log      = SemanticLogger::Log.new("JsonTest", level)
          log.time = log_time
          log
        end

        let(:expected_time) do
          SemanticLogger::Formatters::Base::PRECISION == 3 ? "2017-01-14T08:32:05.375Z" : "2017-01-14T08:32:05.375276Z"
        end

        let(:formatter) do
          formatter = SemanticLogger::Formatters::Json.new(log_host: false)
          # Does not use the logger instance for formatting purposes
          formatter.call(log, nil)
          formatter
        end

        describe "call" do
          it "sets timestamp, level, level_index, and message at the beginning of the JSON object" do
            log.message = "Some message"
            expected_start = %({"timestamp":"#{expected_time}","level":"debug","level_index":1,"message":"Some message")

            is_starting_with_high_priority_fields = formatter.call(log, nil).start_with?(expected_start)

            assert is_starting_with_high_priority_fields, "Expected #{formatter.call(log, nil)} to start with #{expected_start}"
          end
        end
      end
    end
  end
end
