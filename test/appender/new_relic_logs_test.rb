require_relative "../test_helper"

add_mocks_to_load_path

# Unit Test for SemanticLogger::Appender::NewRelicLogs
module Appender
  class NewRelicLogsTest < Minitest::Test
    describe SemanticLogger::Appender::NewRelicLogs do
      before do
        @appender = SemanticLogger::Appender::NewRelicLogs.new
        @message  = "AppenderNewRelicTest log message"
        NewRelic::Agent.metadata_enabled = true
      end

      after do
        NewRelic::Agent.metadata_enabled = false
      end

      def log_newrelic_stub(message, level)
        @logged_message = message
        @logged_level = level
      end

      def parse_logged_message
        @hash = begin
          JSON.parse(@logged_message)
        rescue StandardError
          nil
        end
        begin
          @message_hash = JSON.parse(@hash["message"]) if @hash && @hash["message"].is_a?(String)
        rescue StandardError
          nil
        end
      end

      SemanticLogger::Levels::LEVELS.each do |level|
        it "sends :#{level} notifications to New Relic" do
          NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
            @appender.tagged("test") do
              @appender.send(level, @message)
            end
          end

          parse_logged_message

          refute_nil @hash, "Expected @hash to be parsed JSON"
          assert_equal @message, @hash["message"]
          assert_equal ["test"], @hash["tags"]
          assert_nil @hash.dig("duration", "ms")
          assert @hash.dig("thread", "name"), @hash.inspect
          assert_equal @logged_level, level.to_s.upcase
        end
      end

      it "uses the New Relic Logs formatter by default" do
        assert_instance_of SemanticLogger::Formatters::NewRelicLogs, @appender.formatter
      end

      it "uses the New Relic Logs formatter when given a nil formatter" do
        given_nil = SemanticLogger::Appender::NewRelicLogs.new(formatter: nil)

        assert_instance_of SemanticLogger::Formatters::NewRelicLogs, given_nil.formatter
      end

      it "restores the New Relic Logs formatter when the formatter is set to nil" do
        @appender.formatter = :json
        @appender.formatter = nil

        assert_instance_of SemanticLogger::Formatters::NewRelicLogs, @appender.formatter
      end

      it "sends notification to New Relic with custom attributes" do
        SemanticLogger::Appender::NewRelicLogs.stub(:log_newrelic, method(:log_newrelic_stub)) do
          SemanticLogger.tagged("test") do
            SemanticLogger.named_tagged(key1: 1, key2: "a") do
              @appender.measure_error(message: @message, payload: {key3: 4}) do
                sleep 0.001
              end
            end
          end
        end

        parse_logged_message

        refute_nil @hash, "Expected @hash to be parsed JSON"
        assert_equal @message, @hash["message"]
        assert_equal ["test"], @hash["tags"]
        assert @hash.dig("duration", "ms"), "Expected duration to be logged"
        assert_equal 1, @hash["key1"]
        assert_equal "a", @hash["key2"]
        assert payload = @hash["payload"], @hash.inspect
        assert_equal 4, payload["key3"]
      end

      it "includes NewRelic's linking metadata" do
        NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
          log = SemanticLogger::Log.new("TestLogger", :info)
          SemanticLogger::Logger.call_subscribers(log)
          @appender.log(log)
        end
        parse_logged_message

        refute_nil @hash, "Expected @hash to be parsed JSON"
        assert_equal "Entity Name", @hash["entity.name"]
      end

      it "handles large payloads gracefully" do
        large_payload = {data: "a" * 10_000}
        log = SemanticLogger::Log.new("TestLogger", :info)
        log.payload = large_payload

        NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
          @appender.log(log)
        end

        parse_logged_message

        refute_nil @hash, "Expected @hash to be parsed JSON"
        assert_equal large_payload[:data], @hash.dig("payload", "data")
      end

      it "handles deeply nested payloads gracefully" do
        nested_payload = {level1: {level2: {level3: {level4: "deep_value"}}}}
        log = SemanticLogger::Log.new("TestLogger", :info)
        log.payload = nested_payload

        NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
          @appender.log(log)
        end

        parse_logged_message

        refute_nil @hash, "Expected @hash to be parsed JSON"
        assert_equal "deep_value", @hash.dig("payload", "level1", "level2", "level3", "level4")
      end

      it "raises an error that converting the entry to JSON raises" do
        unserializable = Object.new
        def unserializable.to_json(*)
          raise ArgumentError, "bug in #to_json"
        end
        # Set @formatter directly: passing a callable to #stub or #formatter= would be
        # invoked rather than returned, masking the path under test.
        @appender.instance_variable_set(:@formatter, ->(_log, _appender) { unserializable })
        log = SemanticLogger::Log.new("TestLogger", :info)

        NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
          error = assert_raises(ArgumentError) { @appender.log(log) }

          assert_equal "bug in #to_json", error.message
        end

        # log_newrelic is never reached when serialization fails.
        assert_nil @logged_message
      end

      it "raises a formatter error as a format error" do
        @appender.instance_variable_set(:@formatter, ->(_log, _appender) { raise "boom" })
        log = SemanticLogger::Log.new("TestLogger", :info)

        NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
          error = assert_raises(SemanticLogger::Subscriber::FormatError) { @appender.log(log) }

          assert_kind_of RuntimeError, error.cause
          assert_equal "boom", error.cause.message
        end

        assert_nil @logged_message
      end

      it "raises when the New Relic agent has not started" do
        log = SemanticLogger::Log.new("TestLogger", :info)

        NewRelic::Agent.stub(:agent, nil) do
          assert_raises(NoMethodError) { @appender.log(log) }
        end
      end

      it "treats every error as one that writing the entry again cannot fix" do
        assert @appender.message_error?(NoMethodError.new("undefined method 'log_event_aggregator' for nil"))
        assert @appender.message_error?(ArgumentError.new("bug in #to_json"))
        assert @appender.message_error?(SemanticLogger::Subscriber::FormatError.new("Could not format"))
      end

      describe "asynchronously" do
        let(:internal) { SemanticLogger::Test::CaptureLogEvents.new }

        before do
          @appender.logger = internal
          @proxy           = SemanticLogger::Appender::Async.new(appender: @appender)
        end

        after do
          @proxy.close
        end

        it "counts the entries it could not write as failed, and reports them once, without backing off" do
          NewRelic::Agent.stub(:agent, nil) do
            3.times { |i| @proxy.log(SemanticLogger::Log.new("TestLogger", :info).tap { |log| log.message = "m#{i}" }) }
            @proxy.flush
          end

          assert_equal 3, @proxy.failed_count
          assert_equal 0, @proxy.processed_count
          assert_predicate @proxy, :active?, "Expected the worker thread to carry on"
          reports = internal.events.reject { |event| event.level == :trace }

          assert_equal 1, reports.size, reports.map(&:message).inspect
          assert_equal :error, reports.first.level
          assert_includes reports.first.message, "Discarded 1 log message(s)"
          assert_kind_of NoMethodError, reports.first.exception
        end

        it "writes entries again once the agent is available" do
          NewRelic::Agent.stub(:agent, nil) do
            @proxy.log(SemanticLogger::Log.new("TestLogger", :info))
            @proxy.flush
          end
          NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
            log         = SemanticLogger::Log.new("TestLogger", :info)
            log.message = "after"
            @proxy.log(log)
            @proxy.flush
          end

          assert_equal 1, @proxy.failed_count
          assert_equal 1, @proxy.processed_count
          parse_logged_message

          assert_equal "after", @hash["message"]
        end
      end
    end
  end
end
