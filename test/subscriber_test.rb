require_relative "test_helper"
require "stringio"

class SubscriberTest < Minitest::Test
  class SimpleSubscriber < SemanticLogger::Subscriber
    attr_accessor :event, :message

    def log(log)
      self.message = formatter.call(log, self) << "\n"
      self.event   = log
      true
    end
  end

  describe SemanticLogger::Subscriber do
    let(:appender) { SimpleSubscriber.new }
    let(:hash_value) { {session_id: "HSSKLEU@JDK767", tracking_number: 12_345} }
    let(:hash_str) { hash_value.inspect.sub("{", '\\{').sub("}", '\\}') }
    let(:file_name_reg_exp) { ' subscriber_test.rb:\d+' }

    before do
      Thread.current.name = Thread.current.object_id
    end

    describe "format logs into text form" do
      it "handle no message or payload" do
        appender.debug
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber\n/, appender.message)
      end

      it "handle message" do
        appender.debug "hello world"
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber -- hello world\n/, appender.message)
      end

      it "handle message and payload" do
        appender.debug "hello world", hash_value
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber -- hello world -- #{hash_str}\n/, appender.message)
      end

      it "handle message, payload, and exception" do
        appender.debug "hello world", hash_value, StandardError.new("StandardError")
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber -- hello world -- #{hash_str} -- Exception: StandardError: StandardError\n\n/, appender.message)
      end

      it "logs exception with nil backtrace" do
        appender.debug StandardError.new("StandardError")
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber -- Exception: StandardError: StandardError\n\n/, appender.message)
      end

      it "handle nested exception" do
        begin
          raise StandardError, "FirstError"
        rescue Exception
          begin
            raise StandardError, "SecondError"
          rescue Exception => e
            appender.debug e
          end
        end
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber -- Exception: StandardError: SecondError\n/, appender.message)
        assert_match(/^Cause: StandardError: FirstError\n/, appender.message) if Exception.instance_methods.include?(:cause)
      end

      it "logs exception with empty backtrace" do
        exc = StandardError.new("StandardError")
        exc.set_backtrace([])
        appender.debug exc
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber -- Exception: StandardError: StandardError\n\n/, appender.message)
      end

      it "ignores metric only messages" do
        appender.debug metric: "my/custom/metric"
        assert_nil appender.message
      end

      it "ignores metric only messages with payload" do
        appender.debug metric: "my/custom/metric", payload: {hello: :world}
        assert_nil appender.message
      end
    end

    describe "for each log level" do
      # Ensure that any log level can be logged
      SemanticLogger::LEVELS.each do |level|
        it "log #{level} with file_name" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            appender.send(level, "hello world", hash_value)
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber -- hello world -- #{hash_str}\n/, appender.message)
          end
        end

        it "log #{level} without file_name" do
          SemanticLogger.stub(:backtrace_level_index, 100) do
            appender.send(level, "hello world", hash_value)
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:\w+\] SubscriberTest::SimpleSubscriber -- hello world -- #{hash_str}\n/, appender.message)
          end
        end
      end
    end

    describe "custom formatter" do
      let :appender do
        SubscriberTest::SimpleSubscriber.new do |log|
          tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags&.size&.positive?

          message = log.message.to_s
          message << " -- " << log.payload.inspect if log.payload
          if log.exception
            message << " -- " << "#{log.exception.class}: #{log.exception.message}\n#{(log.exception.backtrace || []).join("\n")}"
          end

          duration_str = log.duration ? " (#{format('%.1f', log.duration)}ms)" : ""

          formatted_time = log.time.strftime(SemanticLogger::Formatters::Base.build_time_format)

          "#{formatted_time} #{log.level.to_s.upcase} [#{$$}:#{log.thread_name}] #{tags}#{log.name} -- #{message}#{duration_str}"
        end
      end

      it "format using formatter" do
        appender.debug
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ DEBUG \[\d+:\w+\] SubscriberTest::SimpleSubscriber -- \n/, appender.message)
      end
    end

    describe "#console_output?" do
      it "is false by default" do
        refute appender.console_output?
      end
    end
  end
end
