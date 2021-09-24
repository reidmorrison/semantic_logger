require_relative "../test_helper"

module Appender
  class FileTest < Minitest::Test
    describe SemanticLogger::Appender::File do
      let(:log_message) { "Hello World" }
      let(:thread_name) { "Worker 001" }
      let(:file_name) { ".quick_test.log" }
      let(:appender) { SemanticLogger::Appender::File.new(file_name) }

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
          before_log = appender.instance_variable_get(:@file)
          appender.stub(:time_to_reopen?, false) do
            appender.log(log)
          end
          assert_equal before_log.object_id, appender.instance_variable_get(:@file).object_id
        end

        it "reopens when time to reopen" do
          before_log = appender.instance_variable_get(:@file)
          appender.stub(:time_to_reopen?, true) do
            appender.log(log)
          end
          refute_equal before_log.object_id, appender.instance_variable_get(:@file).object_id
        end

        describe "retry_count" do
          # The local file system writes the output to nowhere when the file is deleted.
          # This logic is for shared file systems that return an exception when the file
          # cannot be written to because it was deleted, etc.
          it "Creates a new file when an exception is raised writing to the file" do
            assert appender.log(log)
            File.unlink(file_name)
            before_log = appender.instance_variable_get(:@file)
            appender.instance_variable_get(:@file).stub(:write, -> { raise(IOError, "Oh no") }) do
              assert appender.log(log)
            end
            assert_equal 1, File.read(file_name).lines.count
            refute_equal before_log.object_id, appender.instance_variable_get(:@file).object_id
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
          before_log = appender.instance_variable_get(:@file)
          assert_equal 1, File.read(file_name).lines.count
          assert appender.reopen
          assert appender.log(log)
          assert_equal 2, File.read(file_name).lines.count
          refute_equal before_log.object_id, appender.instance_variable_get(:@file).object_id
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
            before_log = appender.instance_variable_get(:@file)

            20.times { appender.info("Hello world how are you doing") }
            assert appender.log_size > 250

            refute_equal before_log.object_id, appender.instance_variable_get(:@file).object_id
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
            before_log = appender.instance_variable_get(:@file)
            5.times { appender.info("Hello world how are you doing this time around with some larger messages?") }
            refute_equal 10, appender.log_count
            refute_equal before_log.object_id, appender.instance_variable_get(:@file).object_id
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
    end
  end
end
