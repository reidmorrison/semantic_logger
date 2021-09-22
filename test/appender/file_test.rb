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

        # The local file system writes the output to nowhere when the file is deleted.
        # This logic is for shared file systems that return an exception when the file
        # cannot be written to because it was deleted, etc.
        # it "Creates a new file when an exception is raised writing to the file" do
        #   assert appender.log(log)
        #   File.unlink(file_name)
        #   assert appender.log(log)
        #   assert_equal 1, File.read(file_name).lines.count
        # end
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
    end
  end
end
