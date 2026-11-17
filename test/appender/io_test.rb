require_relative "../test_helper"

module Appender
  class IOTest < Minitest::Test
    describe SemanticLogger::Appender::IO do
      let(:log_message) { "Hello World" }
      let(:thread_name) { "Worker 001" }
      let :log do
        log             = SemanticLogger::Log.new("User", :info)
        log.message     = log_message
        log.thread_name = thread_name
        log
      end

      describe "#log" do
        it "logs output" do
          io       = StringIO.new
          appender = SemanticLogger::Appender::IO.new(io)

          assert appender.log(log)
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{thread_name}\] User -- #{log_message}\n/, io.string)
        end
      end

      describe "an IO that converts what it writes to UTF-8" do
        # Such as one opened after Rails sets Encoding.default_internal to UTF-8.
        it "writes binary text that a formatter returns, converted to UTF-8" do
          reader, writer = ::IO.pipe
          writer.set_encoding(Encoding::UTF_8)
          appender = SemanticLogger::Appender::IO.new(writer, formatter: ->(log, _) { log.message })

          appender.info("Café ☕".b)
          writer.close

          assert_equal "Café ☕\n", reader.read
        ensure
          writer&.close unless writer&.closed?
          reader&.close
        end
      end

      describe "#flush" do
        it "flushes output" do
          appender = SemanticLogger::Appender::IO.new($stdout)

          assert appender.flush
        end
      end

      describe "#console_output?" do
        it "logs to stdout" do
          appender = SemanticLogger::Appender::IO.new($stdout)

          assert_predicate appender, :console_output?
        end

        it "logs to stderr" do
          appender = SemanticLogger::Appender::IO.new($stderr)

          assert_predicate appender, :console_output?
        end

        it "logs to other" do
          io       = StringIO.new
          appender = SemanticLogger::Appender::IO.new(io)

          refute_predicate appender, :console_output?
        end
      end

      describe "#console_stream" do
        it "is :stdout when writing to stdout" do
          appender = SemanticLogger::Appender::IO.new($stdout)

          assert_equal :stdout, appender.console_stream
        end

        it "is :stderr when writing to stderr" do
          appender = SemanticLogger::Appender::IO.new($stderr)

          assert_equal :stderr, appender.console_stream
        end

        it "is nil for other streams" do
          io       = StringIO.new
          appender = SemanticLogger::Appender::IO.new(io)

          assert_nil appender.console_stream
        end
      end
    end
  end
end
