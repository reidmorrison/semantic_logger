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
        # Records each request, and rejects one that AWS would reject.
        let(:client) do
          requests = []
          client   = Object.new
          client.define_singleton_method(:requests) { requests }
          client.define_singleton_method(:put_log_events) do |params|
            events = params[:log_events]
            # As the AWS SDK does, which raises for invalid UTF-8.
            JSON.generate(events)
            bytes = events.sum { |event| event[:message].bytesize + 26 }
            if bytes > 1_048_576 || events.size > 10_000 || events.any? { |event| event[:message].empty? }
              raise Aws::CloudWatchLogs::Errors::InvalidParameterException.new(nil, "Invalid log events")
            end

            requests << params
            Aws::CloudWatchLogs::Types::PutLogEventsResponse.new
          end
          client
        end

        let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }

        let(:appender) do
          Aws::CloudWatchLogs::Client.stub :new, client do
            SemanticLogger::Appender::CloudwatchLogs.new(
              group: log_group, stream: log_stream, force_flush_interval_seconds: 3_600
            ).tap { |appender| appender.logger = internal_logger }
          end
        end

        after do
          appender.close
        end

        def buffer(message, time = Time.now)
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = message
          log.time    = time
          appender.log(log)
        end

        # Returns the log event messages sent in each request.
        def sent_events
          client.requests.map { |request| request[:log_events].map { |event| event[:message] } }
        end

        # Returns the log messages sent in each request.
        def sent_messages
          sent_events.map { |events| events.map { |event| JSON.parse(event)["message"] } }
        end

        # Returns the first characters of the log messages sent in each request.
        def sent_prefixes
          sent_messages.map { |messages| messages.map { |message| message[0, 5] } }
        end

        # Makes the next request fail as AWS does when the log group or stream is missing, then
        # send the requests after it.
        def missing(*resources)
          original = client.method(:put_log_events)
          client.define_singleton_method(:put_log_events) do |params|
            resource = resources.shift
            return original.call(params) unless resource

            raise Aws::CloudWatchLogs::Errors::ResourceNotFoundException.new(nil, "The log #{resource} does not exist.")
          end
        end

        def reported_messages
          internal_logger.events.map(&:message)
        end

        it "splits them into batches that fit the size limit" do
          ["first", "A" * 600_000, "B" * 600_000, "last"].each { |message| buffer(message) }
          appender.send(:put_log_events)

          assert_equal [%w[first AAAAA], %w[BBBBB last]], sent_prefixes
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

        it "raises from #log for a log message that AWS would reject, and sends the others" do
          appender.formatter = lambda do |log, _logger|
            {"nil" => nil, "empty" => "", "hash" => {message: "hash"}}.fetch(log.message) { log.message.to_json }
          end
          buffer("first")

          %w[nil empty hash].each do |message|
            assert_raises(SemanticLogger::Subscriber::FormatError) { buffer(message) }
          end
          buffer("last")
          appender.send(:put_log_events)

          assert_equal [['"first"', '"last"']], sent_events
        end

        it "sends invalid UTF-8 as valid UTF-8, instead of failing the request" do
          appender.formatter = ->(log, _logger) { log.message }
          buffer("caf\xC3")
          buffer("ok")
          appender.send(:put_log_events)

          assert_equal [%w[caf ok]], sent_events
        end

        it "reports a batch that AWS rejects, instead of losing it without a trace" do
          client.define_singleton_method(:put_log_events) do |_params|
            raise Aws::CloudWatchLogs::Errors::ThrottlingException.new(nil, "Rate exceeded")
          end
          buffer("hello")
          appender.send(:put_log_events)

          assert_equal ["Could not send 1 log message(s) to CloudWatch Logs"], reported_messages
          assert_empty appender.buffered_logs
        end

        it "reports a failure to create the missing log stream, and still sends the other batches" do
          missing(:stream)
          client.define_singleton_method(:create_log_stream) do |_params|
            raise Aws::CloudWatchLogs::Errors::ServiceUnavailableException.new(nil, "Unavailable")
          end
          ["A" * 600_000, "B" * 600_000].each { |message| buffer(message) }
          appender.send(:put_log_events)

          assert_equal ["Could not send 1 log message(s) to CloudWatch Logs"], reported_messages
          assert_equal [%w[BBBBB]], sent_prefixes
        end

        it "creates the missing log group and log stream, then sends the batch" do
          created = []
          client.define_singleton_method(:create_log_group) { |params| created << [:group, params] }
          client.define_singleton_method(:create_log_stream) { |params| created << [:stream, params] }
          appender.instance_variable_set(:@create_group, true)
          missing(:group, :stream)
          buffer("hello")
          appender.send(:put_log_events)

          expected = [
            [:group, {log_group_name: log_group}],
            [:stream, {log_group_name: log_group, log_stream_name: log_stream}]
          ]

          assert_equal expected, created
          assert_equal [%w[hello]], sent_messages
          assert_empty reported_messages
        end

        it "sends the batch when another process created the log stream meanwhile" do
          client.define_singleton_method(:create_log_stream) do |_params|
            raise Aws::CloudWatchLogs::Errors::ResourceAlreadyExistsException.new(nil, "Already exists")
          end
          missing(:stream)
          buffer("hello")
          appender.send(:put_log_events)

          assert_equal [%w[hello]], sent_messages
          assert_empty reported_messages
        end

        it "reports, rather than retrying forever, a log stream still missing after creating it" do
          created = 0
          client.define_singleton_method(:create_log_stream) { |_params| created += 1 }
          missing(:stream, :stream, :stream, :stream)
          buffer("hello")
          appender.send(:put_log_events)

          assert_equal 1, created
          assert_equal ["Could not send 1 log message(s) to CloudWatch Logs"], reported_messages
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
