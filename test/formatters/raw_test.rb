require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class RawTest < Minitest::Test
      describe Raw do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          log      = SemanticLogger::Log.new("RawTest", level)
          log.time = log_time
          log
        end

        # Stand-in for the appender / subscriber that owns host/application/environment.
        let(:appender) do
          Struct.new(:host, :application, :environment).new("test_host", "test_app", "test_env")
        end

        let(:set_exception) do
          raise "Oh no"
        rescue Exception => e
          log.exception = e
        end

        let(:backtrace) do
          [
            "test/formatters/raw_test.rb:99:in `block (2 levels) in <class:RawTest>'",
            "lib/minitest/spec.rb:247:in `instance_eval'"
          ]
        end

        let(:formatter) do
          formatter = SemanticLogger::Formatters::Raw.new
          formatter.call(log, appender)
          formatter
        end

        describe "host, application, environment" do
          it "logs them from the appender" do
            assert_equal "test_host", formatter.hash[:host]
            assert_equal "test_app",  formatter.hash[:application]
            assert_equal "test_env",  formatter.hash[:environment]
          end

          it "omits host when log_host is false" do
            formatter = SemanticLogger::Formatters::Raw.new(log_host: false)
            formatter.call(log, appender)

            refute formatter.hash.key?(:host)
          end

          it "omits application when log_application is false" do
            formatter = SemanticLogger::Formatters::Raw.new(log_application: false)
            formatter.call(log, appender)

            refute formatter.hash.key?(:application)
          end

          it "omits environment when log_environment is false" do
            formatter = SemanticLogger::Formatters::Raw.new(log_environment: false)
            formatter.call(log, appender)

            refute formatter.hash.key?(:environment)
          end

          it "omits values that are nil on the appender" do
            appender = Struct.new(:host, :application, :environment).new(nil, nil, nil)
            formatter = SemanticLogger::Formatters::Raw.new
            formatter.call(log, appender)

            refute formatter.hash.key?(:host)
            refute formatter.hash.key?(:application)
            refute formatter.hash.key?(:environment)
          end
        end

        describe "time" do
          it "does not reformat the time by default" do
            assert_equal log_time, formatter.hash[:time]
          end

          it "uses the :time key by default" do
            assert formatter.hash.key?(:time)
          end

          it "supports a custom time_key" do
            formatter = SemanticLogger::Formatters::Raw.new(time_key: :timestamp)
            formatter.call(log, appender)

            assert formatter.hash.key?(:timestamp)
            refute formatter.hash.key?(:time)
          end

          it "supports a time_format" do
            formatter = SemanticLogger::Formatters::Raw.new(time_format: :iso_8601)
            formatter.call(log, appender)

            assert_equal "2017-01-14T08:32:05.375276Z", formatter.hash[:time]
          end
        end

        describe "level" do
          it "logs level and level_index" do
            assert_equal :debug, formatter.hash[:level]
            assert_equal log.level_index, formatter.hash[:level_index]
          end
        end

        describe "pid" do
          it "logs the process id" do
            assert_equal $$, formatter.hash[:pid]
          end
        end

        describe "thread_name" do
          it "logs the thread name" do
            log.thread_name = "main-thread"

            assert_equal "main-thread", formatter.hash[:thread]
          end
        end

        describe "file_name_and_line" do
          it "logs file and line from the backtrace" do
            log.backtrace = backtrace

            assert_equal "test/formatters/raw_test.rb", formatter.hash[:file]
            assert_equal 99, formatter.hash[:line]
          end

          it "is omitted without a backtrace" do
            refute formatter.hash.key?(:file)
            refute formatter.hash.key?(:line)
          end
        end

        describe "duration" do
          it "logs duration_ms and human duration" do
            log.duration = 1.34567

            assert_in_delta(1.34567, formatter.hash[:duration_ms])
            assert_equal log.duration_human, formatter.hash[:duration]
          end

          it "is omitted without a duration" do
            refute formatter.hash.key?(:duration_ms)
            refute formatter.hash.key?(:duration)
          end
        end

        describe "tags" do
          it "logs tags" do
            log.tags = %w[first second]

            assert_equal %w[first second], formatter.hash[:tags]
          end

          it "skips empty tags" do
            log.tags = []

            refute formatter.hash.key?(:tags)
          end
        end

        describe "named_tags" do
          it "logs named tags" do
            log.named_tags = {first: 1, second: 2}

            assert_equal({first: 1, second: 2}, formatter.hash[:named_tags])
          end

          it "skips empty named tags" do
            log.named_tags = {}

            refute formatter.hash.key?(:named_tags)
          end
        end

        describe "name" do
          it "logs the name" do
            assert_equal "RawTest", formatter.hash[:name]
          end
        end

        describe "message" do
          it "logs the message" do
            log.message = "Hello World"

            assert_equal "Hello World", formatter.hash[:message]
          end

          it "is omitted when there is no message" do
            refute formatter.hash.key?(:message)
          end
        end

        describe "payload" do
          it "logs a hash payload" do
            log.payload = {first: 1, second: 2}

            assert_equal({first: 1, second: 2}, formatter.hash[:payload])
          end

          it "skips an empty payload" do
            log.payload = {}

            refute formatter.hash.key?(:payload)
          end

          it "skips a nil payload" do
            refute formatter.hash.key?(:payload)
          end
        end

        describe "exception" do
          it "logs the exception" do
            set_exception
            exception = formatter.hash[:exception]

            assert_equal "RuntimeError", exception[:name]
            assert_equal "Oh no", exception[:message]
            assert exception.key?(:stack_trace)
          end

          it "logs a nested cause" do
            begin
              begin
                raise "the cause"
              rescue StandardError
                raise "the effect"
              end
            rescue Exception => e
              log.exception = e
            end

            assert_equal "the effect", formatter.hash[:exception][:message]
            assert_equal "the cause", formatter.hash[:exception][:cause][:message]
          end

          it "is omitted without an exception" do
            refute formatter.hash.key?(:exception)
          end
        end

        describe "metric" do
          it "logs metric and amount" do
            log.metric        = "user/login"
            log.metric_amount = 3

            assert_equal "user/login", formatter.hash[:metric]
            assert_equal 3, formatter.hash[:metric_amount]
          end

          it "is omitted without a metric" do
            refute formatter.hash.key?(:metric)
            refute formatter.hash.key?(:metric_amount)
          end
        end

        describe "call" do
          it "returns a hash" do
            assert_kind_of Hash, formatter.call(log, appender)
          end

          it "includes the core fields" do
            hash = formatter.call(log, appender)

            assert_equal :debug, hash[:level]
            assert_equal "RawTest", hash[:name]
            assert_equal $$, hash[:pid]
          end
        end
      end
    end
  end
end
