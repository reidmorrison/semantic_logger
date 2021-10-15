require_relative "../test_helper"

module Appender
  class FileTest < Minitest::Test
    describe SemanticLogger::Appender::File do
      let(:log_message) { "Hello World" }
      let(:thread_name) { "Worker 001" }
      let(:file_name) { ".quick_test.log" }
      let(:appender) { SemanticLogger::Appender::File.new(file_name) }
      let(:current_time) { Time.parse("2015-12-09 17:50:05") }

      let :log do
        log             = SemanticLogger::Log.new("User", :info)
        log.message     = log_message
        log.thread_name = thread_name
        log
      end

      after do
        File.unlink(file_name) if File.exist?(file_name)
      end

      describe "#log" do
        it "logs output" do
          assert appender.log(log)
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{thread_name}\] User -- #{log_message}\n/, File.read(file_name))
        end

        it "does not reopen when not time to reopen" do
          appender.log(log)
          refute appender.send(:time_to_reopen?)
          refute_file_reopened(appender) do
            appender.stub(:time_to_reopen?, false) do
              appender.log(log)
            end
          end
        end

        it "reopens when time to reopen" do
          assert_file_reopened(appender) do
            appender.stub(:time_to_reopen?, true) do
              appender.log(log)
            end
          end
        end

        describe "retry_count" do
          # The local file system writes the output to nowhere when the file is deleted.
          # This logic is for shared file systems that return an exception when the file
          # cannot be written to because it was deleted, etc.
          it "Creates a new file when an exception is raised writing to the file" do
            assert appender.log(log)
            File.unlink(file_name)
            assert_file_reopened(appender) do
              appender.instance_variable_get(:@file).stub(:write, -> { raise(IOError, "Oh no") }) do
                assert appender.log(log)
              end
              assert_equal 1, File.read(file_name).lines.count
            end
          end

          it "when retry is disabled" do
            appender.retry_count = 0
            assert appender.log(log)
            File.unlink(file_name)
            appender.instance_variable_get(:@file).stub(:write, -> _ { raise(IOError, "Oh no") }) do
              assert_raises IOError do
                appender.log(log)
              end
            end
            refute File.exist?(file_name)
          end
        end
      end

      describe "#reopen" do
        it "Opens a new file" do
          assert appender.log(log)
          assert_file_reopened(appender) do
            assert_equal 1, File.read(file_name).lines.count
            assert appender.reopen
            assert appender.log(log)
            assert_equal 2, File.read(file_name).lines.count
          end
        end

        it "Creates a new file on reopen" do
          assert appender.log(log)
          File.unlink(file_name)
          assert appender.reopen
          assert appender.log(log)
          assert_equal 1, File.read(file_name).lines.count
        end

        it "exclusive_lock" do
          appender.exclusive_lock = true
          assert appender.reopen
          assert appender.log(log)
          assert_equal 1, File.read(file_name).lines.count
          exception = assert_raises(ArgumentError) do
            File.open("w+", file_name) { |file| file.write("Cannot share") }
          end
          assert_includes(exception.message, "invalid access mode")
        end
      end

      describe "#flush" do
        it "flushes output" do
          refute appender.flush
        end

        it "flushes output after logging" do
          appender.debug("Hello")
          assert appender.flush
        end
      end

      describe "#time_to_reopen?" do
        it "before anything is logged" do
          assert appender.send(:time_to_reopen?)
        end

        describe "reopen_count" do
          let(:appender) { SemanticLogger::Appender::File.new(file_name, reopen_count: 10) }

          it "opens a new log file after 10 log entries" do
            assert_equal 0, appender.log_count
            9.times { appender.info("Hello") }
            assert_equal 9, appender.log_count

            refute appender.send(:time_to_reopen?)
            appender.info("Hello")
            assert appender.send(:time_to_reopen?)
            assert_equal 10, appender.log_count

            appender.info("Hello")
            assert_equal 1, appender.log_count
          end
        end

        describe "reopen_size" do
          let(:appender) { SemanticLogger::Appender::File.new(file_name, reopen_size: 250) }

          it "opens a new log file after every 250 bytes written" do
            assert_equal 0, appender.log_size
            appender.info("Hello world how are you doing")
            assert appender.log_size > 10
            refute appender.send(:time_to_reopen?)
            assert_file_reopened(appender) do
              20.times { appender.info("Hello world how are you doing") }
              assert appender.log_size > 250
            end
          end
        end

        describe "reopen_period" do
          let(:appender) { SemanticLogger::Appender::File.new(file_name, reopen_period: "1m") }

          it "opens a new log file at the beginning of the next minute" do
            assert_nil appender.reopen_at

            Time.stub(:now, current_time) do
              appender.info("Hello world how are you doing")
              refute appender.send(:time_to_reopen?)
            end
            assert_equal Time.parse("2015-12-09 17:51:00"), appender.reopen_at
            assert appender.send(:time_to_reopen?)

            assert_file_reopened(appender) do
              appender.info("Hello world how are you doing")
            end
          end
        end

        describe "reopen_count and reopen_size" do
          let(:appender) { SemanticLogger::Appender::File.new(file_name, reopen_count: 10, reopen_size: 1000) }

          it "logs small messages" do
            assert_equal 0, appender.log_count
            9.times { appender.info("Hello") }
            assert_equal 9, appender.log_count

            refute appender.send(:time_to_reopen?)
            appender.info("Hello")
            assert appender.send(:time_to_reopen?)
            assert_equal 10, appender.log_count

            appender.info("Hello")
            assert_equal 1, appender.log_count
          end

          it "logs large messages" do
            assert_equal 0, appender.log_count
            5.times { appender.info("Hello world how are you doing this time around with some larger messages?") }
            assert_equal 5, appender.log_count

            refute appender.send(:time_to_reopen?)
            assert_file_reopened(appender) do
              5.times { appender.info("Hello world how are you doing this time around with some larger messages?") }
              refute_equal 10, appender.log_count
            end
          end
        end
      end

      describe "#apply_format_directives" do
        it "explicit %" do
          file_name = "log/production-%%.log"
          formatted = appender.send(:apply_format_directives, file_name)
          assert_equal "log/production-%.log", formatted
        end

        it "short hostname" do
          file_name = "log/production-%n.log"
          formatted =
            SemanticLogger.stub(:host, "myserver.domain.org") do
              appender.send(:apply_format_directives, file_name)
            end
          assert_equal "log/production-myserver.log", formatted
        end

        it "long hostname" do
          file_name = "log/production-%N.log"
          formatted =
            SemanticLogger.stub(:host, "myserver.domain.org") do
              appender.send(:apply_format_directives, file_name)
            end
          assert_equal "log/production-myserver.domain.org.log", formatted
        end

        it "application" do
          file_name = "log/production-%a.log"
          formatted =
            SemanticLogger.stub(:application, "my_app") do
              appender.send(:apply_format_directives, file_name)
            end
          assert_equal "log/production-my_app.log", formatted
        end

        it "environment" do
          file_name = "log/production-%e.log"
          formatted =
            SemanticLogger.stub(:environment, "this_environment") do
              appender.send(:apply_format_directives, file_name)
            end
          assert_equal "log/production-this_environment.log", formatted
        end

        it "process id" do
          file_name = "log/production-%p.log"
          formatted = appender.send(:apply_format_directives, file_name)
          assert_equal "log/production-#{$$}.log", formatted
        end

        it "date" do
          file_name = "log/production-%D.log"
          formatted = appender.send(:apply_format_directives, file_name)
          assert_equal "log/production-#{Date.today.strftime("%Y%m%d")}.log", formatted
        end

        it "time" do
          file_name = "log/production-%T.log"
          time      = Time.parse("2015-12-09 17:50:05 UTC")
          formatted =
            Time.stub(:now, time) do
              appender.send(:apply_format_directives, file_name)
            end
          assert_equal "log/production-#{time.strftime("%H%M%S")}.log", formatted
        end

        it "combination" do
          file_name = "log/production-%%-%n-%p-%D-%T.log"
          time      = Time.parse("2015-12-09 17:50:05 UTC")
          formatted =
            Time.stub(:now, time) do
              SemanticLogger.stub(:host, "myserver.domain.org") do
                appender.send(:apply_format_directives, file_name)
              end
            end
          assert_equal "log/production-%-myserver-#{$$}-#{Date.today.strftime("%Y%m%d")}-#{time.strftime("%H%M%S")}.log", formatted
        end

        it "custom time" do
          file_name = "log/production-%H-%M-%S.log"
          time      = Time.parse("2015-12-09 17:50:05 UTC")
          formatted =
            Time.stub(:now, time) do
              appender.send(:apply_format_directives, file_name)
            end
          assert_equal "log/production-#{time.strftime("%H-%M-%S")}.log", formatted
        end

        it "custom date" do
          file_name = "log/production-%Y-%C-%y-%m-%d-%j-%U-%W.log"
          formatted = appender.send(:apply_format_directives, file_name)
          assert_equal "log/production-#{Date.today.strftime("%Y-%C-%y-%m-%d-%j-%U-%W")}.log", formatted
        end
      end

      describe "#next_reopen_period" do
        it "returns the next reopen period" do
          reopen_at =
            Time.stub(:now, current_time) do
              appender.send(:next_reopen_period, "1m")
            end
          assert_equal Time.parse("2015-12-09 17:51:00"), reopen_at
        end

        it "returns nil when no period" do
          assert_nil appender.send(:next_reopen_period, nil)
        end
      end

      describe "#parse_period" do
        it "parses period" do
          assert_equal [1, "m"], appender.send(:parse_period, "1m")
          assert_equal [1, "h"], appender.send(:parse_period, "1h")
          assert_equal [1, "d"], appender.send(:parse_period, "1d")
        end

        it "parses durations" do
          assert_equal [30, "m"], appender.send(:parse_period, "30m")
          assert_equal [12, "h"], appender.send(:parse_period, "12h")
          assert_equal [3, "d"], appender.send(:parse_period, "3d")
        end

        it "ignores whitespace" do
          assert_equal [245, "m"], appender.send(:parse_period, "   2 4 5 m    ")
        end

        it "converts float to integer" do
          assert_equal [2, "m"], appender.send(:parse_period, "2.0m")
        end

        it "rejects bad periods" do
          assert_raises(ArgumentError) { appender.send(:parse_period, nil) }
          assert_raises(ArgumentError) { appender.send(:parse_period, "") }
          assert_raises(ArgumentError) { appender.send(:parse_period, "    ") }
          assert_raises(ArgumentError) { appender.send(:parse_period, "m") }
          assert_raises(ArgumentError) { appender.send(:parse_period, "m2") }
          assert_raises(ArgumentError) { appender.send(:parse_period, "2.0am") }
        end
      end

      describe "#calculate_reopen_at" do
        it "rounds off the next minute" do
          reopen_at = appender.send(:calculate_reopen_at, 1, "m", current_time)
          assert_equal Time.parse("2015-12-09 17:51:00"), reopen_at
        end

        it "rounds off multiple minutes" do
          reopen_at = appender.send(:calculate_reopen_at, 10, "m", current_time)
          assert_equal Time.parse("2015-12-09 18:00:00"), reopen_at
        end

        it "rounds off the next hour" do
          reopen_at = appender.send(:calculate_reopen_at, 1, "h", current_time)
          assert_equal Time.parse("2015-12-09 18:00:00"), reopen_at
        end

        it "rounds off multiple minutes" do
          reopen_at = appender.send(:calculate_reopen_at, 10, "h", current_time)
          assert_equal Time.parse("2015-12-10 03:00:00"), reopen_at
        end

        it "rounds off the next day" do
          reopen_at = appender.send(:calculate_reopen_at, 1, "d", current_time)
          assert_equal Time.parse("2015-12-10 00:00:00"), reopen_at
        end

        it "rounds off multiple days" do
          reopen_at = appender.send(:calculate_reopen_at, 10, "d", current_time)
          assert_equal Time.parse("2015-12-19 00:00:00"), reopen_at
        end
      end

      def assert_file_reopened(appender)
        before_log = appender.instance_variable_get(:@file)
        yield
        refute_equal before_log.object_id, appender.instance_variable_get(:@file).object_id
      end

      def refute_file_reopened(appender)
        before_log = appender.instance_variable_get(:@file)
        yield
        assert_equal before_log.object_id, appender.instance_variable_get(:@file).object_id
      end
    end
  end
end
