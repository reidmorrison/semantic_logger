require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::CloudwatchLogs
module Appender
  class CloudwatchLogsTest < Minitest::Test
    describe SemanticLogger::Appender::CloudwatchLogs do
      let(:log_group) { "/test/log/group" }
      let(:log_stream) { "test_stream" }
      let(:log_event) { SemanticLogger::Log.new("Test", :info) }
      let(:mock_client) { Minitest::Mock.new }
      let(:appender) do
        Aws::CloudWatchLogs::Client.stub :new, mock_client do
          SemanticLogger::Appender::CloudwatchLogs.new(
            group:         log_group,
            stream:        log_stream,
            create_group:  true,
            create_stream: true
          )
        end
      end

      describe "#initialize" do
        it "sets the correct attributes" do
          assert_equal log_group, appender.group
          assert_equal log_stream, appender.instance_variable_get(:@stream)
          assert appender.create_group
          assert appender.create_stream
        end
      end

      describe "#log" do
        it "adds log messages to the buffer" do
          assert_empty appender.buffered_logs
          appender.log(log_event)
          refute_empty appender.buffered_logs
        end
      end

      describe "#flush" do
        it "executes task and clears the buffer" do
          mock_client.expect :put_log_events, nil, [Hash]
          appender.log(log_event)
          appender.flush
          assert_empty appender.buffered_logs
        end
      end

      describe "#close" do
        it "shuts down the timer task" do
          assert appender.task.running?
          appender.close
          refute appender.task.running?
        end
      end
    end
  end
end
