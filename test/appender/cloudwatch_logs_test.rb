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

      it "does not show the AWS credentials in #inspect" do
        credentials = {secret_access_key: "aws-s3cr3t"}
        appender    = Aws::CloudWatchLogs::Client.stub :new, mock_client do
          SemanticLogger::Appender::CloudwatchLogs.new(group: log_group, client_kwargs: credentials)
        end

        refute_includes appender.inspect, "aws-s3cr3t"
        assert_includes appender.inspect, %( group="/test/log/group")
      ensure
        appender&.close
      end

      describe "sending the buffered log messages" do
        # Records each request, and rejects one over the PutLogEvents limits, as AWS does.
        let(:client) do
          requests = []
          client   = Object.new
          client.define_singleton_method(:requests) { requests }
          client.define_singleton_method(:put_log_events) do |params|
            events = params[:log_events]
            bytes  = events.sum { |event| event[:message].bytesize + 26 }
            if bytes > 1_048_576 || events.size > 10_000
              raise Aws::CloudWatchLogs::Errors::InvalidParameterException.new(nil, "Upload too large")
            end

            requests << params
          end
          client
        end

        let(:appender) do
          Aws::CloudWatchLogs::Client.stub :new, client do
            SemanticLogger::Appender::CloudwatchLogs.new(
              group: log_group, stream: log_stream, force_flush_interval_seconds: 3_600
            )
          end
        end

        after do
          appender.close
        end

        def buffer(message, time = Time.now)
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = message
          log.time    = time
          appender.buffered_logs << log
        end

        # Returns the messages sent in each request.
        def sent_messages
          client.requests.map do |request|
            request[:log_events].map { |event| JSON.parse(event[:message])["message"] }
          end
        end

        it "splits them into batches that fit the size limit" do
          ["first", "A" * 600_000, "B" * 600_000, "last"].each { |message| buffer(message) }
          appender.send(:put_log_events)

          prefixes = sent_messages.map { |batch| batch.map { |message| message[0, 5] } }

          assert_equal [%w[first AAAAA], %w[BBBBB last]], prefixes
        end

        it "cuts short a log message too large for a batch on its own" do
          buffer("A" * 2_000_000)
          appender.send(:put_log_events)

          assert_equal 1_048_550, client.requests.first[:log_events].first[:message].bytesize
        end

        it "sends the log events in chronological order" do
          now = Time.now
          buffer("second", now)
          buffer("first", now - 1)
          appender.send(:put_log_events)

          assert_equal [%w[first second]], sent_messages
        end

        it "reports a batch that AWS rejects, instead of losing it without a trace" do
          internal        = SemanticLogger::Test::CaptureLogEvents.new
          appender.logger = internal
          client.define_singleton_method(:put_log_events) do |_params|
            raise Aws::CloudWatchLogs::Errors::ThrottlingException.new(nil, "Rate exceeded")
          end
          buffer("hello")
          appender.send(:put_log_events)

          assert_equal ["Could not send 1 log message(s) to CloudWatch Logs"], internal.events.map(&:message)
          assert_empty appender.buffered_logs
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
          assert_predicate appender.task, :running?
          appender.close

          refute_predicate appender.task, :running?
        end
      end
    end
  end
end
