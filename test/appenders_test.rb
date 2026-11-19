require_relative "test_helper"
require_relative "signal_trap_helper"

class AppendersTest < Minitest::Test
  class RaisingLogAppender < SemanticLogger::Test::CaptureLogEvents
    def log(_log)
      raise "log boom"
    end
  end

  class OverflowingLogAppender < SemanticLogger::Test::CaptureLogEvents
    def log(_log)
      raise SystemStackError, "stack level too deep"
    end
  end

  class RaisingFlushAppender < SemanticLogger::Test::CaptureLogEvents
    def flush
      raise "flush boom"
    end
  end

  class ReopenAppender < SemanticLogger::Test::CaptureLogEvents
    attr_reader :reopened

    def reopen
      @reopened = true
    end
  end

  class RaisingReopenAppender < SemanticLogger::Test::CaptureLogEvents
    def reopen
      raise "reopen boom"
    end
  end

  # Fails each write because of its destination, as one that cannot be reached does, and records each
  # write and flush.
  class DownAppender < SemanticLogger::Subscriber
    def attempts = @attempts ||= []

    def flushes = @flushes ||= []

    def log(log)
      attempts << log.message
      raise IOError, "destination unavailable"
    end

    def flush
      flushes << true
    end
  end

  # Accepts up to 2 messages, which only its flush delivers, then fails each write, as a :kafka
  # appender does once its producer's buffer is full.
  class HoldingAppender < SemanticLogger::Subscriber
    def delivered = @delivered ||= []

    def held = @held ||= []

    def log(log)
      raise IOError, "buffer full" if held.size >= 2

      held << log.message
    end

    def flush
      delivered.concat(held)
      held.clear
    end
  end

  describe SemanticLogger::Appenders do
    let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }
    let(:appenders) { SemanticLogger::Appenders.new(capture_logger) }
    let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

    after do
      FileUtils.rm_f("sample.log")
    end

    describe "#add" do
      it "adds file appender" do
        appender = appenders.add(file_name: "sample.log")

        assert_kind_of SemanticLogger::Appender::File, appender
        assert_includes appenders, appender
        assert_kind_of SemanticLogger::Formatters::Default, appender.formatter
      end

      it "adds file appender with json format" do
        appender = appenders.add(file_name: "sample.log", formatter: :json)

        assert_kind_of SemanticLogger::Appender::File, appender
        assert_includes appenders, appender
        assert_kind_of SemanticLogger::Formatters::Json, appender.formatter, appender.formatter.inspect
      end

      it "adds stream appender" do
        appender = appenders.add(io: $stdout)

        assert_kind_of SemanticLogger::Appender::IO, appender
        assert_includes appenders, appender
      end

      # :wrapper can only be added with logger:, which add_appender takes as the destination instead.
      it "adds a :wrapper appender from logger:, warning that appender: is ignored" do
        appender = assert_deprecated(/it uses logger: and ignores appender:,/) do
          appenders.add(appender: :wrapper, logger: Logger.new($stdout))
        end

        assert_kind_of SemanticLogger::Appender::Wrapper, appender, -> { appender.ai }
        assert_includes appenders, appender
      end

      it "adds symbol appender with underscores" do
        appender = appenders.add(appender: :bugsnag)

        assert_kind_of SemanticLogger::Appender::Bugsnag, appender, -> { appender.ai }
        assert_includes appenders, appender
      end

      it "adds logger wrapper appender" do
        appender = appenders.add(logger: ::Logger.new($stdout))

        assert_kind_of SemanticLogger::Appender::Wrapper, appender
        assert_kind_of ::Logger, appender.wrapped_logger
        assert_includes appenders, appender
        assert_kind_of SemanticLogger::Formatters::Default, appender.formatter
      end

      it "adds logger wrapper appender with color formatter" do
        appender = appenders.add(logger: ::Logger.new($stdout), formatter: :color)

        assert_kind_of SemanticLogger::Appender::Wrapper, appender
        assert_kind_of ::Logger, appender.wrapped_logger
        assert_includes appenders, appender
        assert_kind_of SemanticLogger::Formatters::Color, appender.formatter
      end

      it "adds appender" do
        appender = appenders.add(appender: SemanticLogger::Appender::IO.new($stdout))

        assert_kind_of SemanticLogger::Appender::IO, appender, appender.ai
        assert_includes appenders, appender
      end

      it "fails to add invalid logger appender" do
        assert_raises ArgumentError do
          appenders.add(logger: "blah")
        end
      end

      it "prevents adding a second appender to the same console stream" do
        appender = appenders.add(io: $stdout)

        assert_includes appenders, appender

        appender = appenders.add(io: $stdout)

        assert_nil appender

        assert_equal 1, appenders.size
      end

      it "allows adding separate stdout and stderr console appenders" do
        stdout_appender = appenders.add(io: $stdout)

        assert_includes appenders, stdout_appender

        stderr_appender = appenders.add(io: $stderr)

        assert_includes appenders, stderr_appender

        assert_equal 2, appenders.size
        assert_equal %i[stdout stderr], appenders.console_streams
      end

      it "allows adding multiple loggers" do
        appender = appenders.add(io: $stdout)

        assert_includes appenders, appender

        appender = appenders.add(file_name: "test.log")

        assert_includes appenders, appender

        assert_equal 2, appenders.size
      end

      it "adds batch proxy" do
        appender = appenders.add(appender: logger, batch: true)

        assert_instance_of SemanticLogger::Appender::Async, appender
        assert_predicate appender, :batch?
      end

      # it "adds async proxy" do
      #   appender = appenders.add(appender: logger, async: true)
      #   assert_instance_of SemanticLogger::Appender::Async, appender
      # end
    end

    describe "#close" do
      it "closes appenders" do
        appenders.add(file_name: "test.log")

        appenders.close

        assert_equal(0, capture_logger.events.count { |it| it.message.match?(/failed/i) })
        assert_equal 0, appenders.size
      end
    end

    describe "#log" do
      it "continues to remaining appenders when one raises and records the failure" do
        failing   = RaisingLogAppender.new
        recording = SemanticLogger::Test::CaptureLogEvents.new
        appenders << failing
        appenders << recording

        log         = SemanticLogger::Log.new("Test", :info)
        log.message = "hello"
        appenders.log(log)

        assert_includes recording.events, log
        assert(capture_logger.events.any? { |it| it.message.include?("Failed to log to appender") })
      end

      it "raises a stack overflow to the processor, without writing to the remaining appenders" do
        recording = SemanticLogger::Test::CaptureLogEvents.new
        appenders << OverflowingLogAppender.new
        appenders << recording

        log         = SemanticLogger::Log.new("Test", :info)
        log.message = "hello"

        assert_raises(SystemStackError) { appenders.log(log) }
        assert_empty recording.events
      end

      describe "with sensitive keys" do
        let(:payload) { {user: "jack", password: "secret"} }
        let(:log) do
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = "hello"
          log.payload = payload
          log
        end

        before { SemanticLogger.sensitive_keys = [:password] }
        after { SemanticLogger.sensitive_keys = nil }

        it "redacts the entry once, before any appender writes it" do
          first  = SemanticLogger::Test::CaptureLogEvents.new
          second = SemanticLogger::Test::CaptureLogEvents.new
          appenders << first
          appenders << second
          appenders.log(log)

          [first, second].each do |appender|
            assert_equal({user: "jack", password: SemanticLogger::Redactor::MASK}, appender.events.first.payload)
          end
          assert_equal "secret", payload[:password]
        end

        it "redacts the entry before an appender's filter reads it" do
          seen = nil
          recording        = SemanticLogger::Test::CaptureLogEvents.new
          recording.filter = ->(log) { (seen = log.payload[:password]) && true }
          appenders << recording
          appenders.log(log)

          assert_equal SemanticLogger::Redactor::MASK, seen
        end

        it "writes the entry as it is when there are no sensitive keys" do
          SemanticLogger.sensitive_keys = nil
          recording = SemanticLogger::Test::CaptureLogEvents.new
          appenders << recording
          appenders.log(log)

          assert_same payload, recording.events.first.payload
        end
      end
    end

    describe "#flush" do
      it "flushes remaining appenders when one raises and records the failure" do
        failing   = RaisingFlushAppender.new
        recording = SemanticLogger::Test::CaptureLogEvents.new
        appenders << failing
        appenders << recording

        appenders.flush

        assert(capture_logger.events.any? { |it| it.message.include?("Failed to flush appender") })
      end
    end

    describe "#reopen" do
      it "reopens appenders that support it and skips those that do not" do
        reopenable     = ReopenAppender.new
        not_reopenable = SemanticLogger::Test::CaptureLogEvents.new
        appenders << reopenable
        appenders << not_reopenable

        appenders.reopen

        assert reopenable.reopened
      end

      it "continues to remaining appenders when one raises and records the failure" do
        failing  = RaisingReopenAppender.new
        succeeds = ReopenAppender.new
        appenders << failing
        appenders << succeeds

        appenders.reopen

        assert succeeds.reopened
        assert(capture_logger.events.any? { |it| it.message.include?("Failed to re-open appender") })
      end
    end

    describe "#process_exiting=" do
      # Records whether it is told that the process is exiting, as an appender added with async: true is.
      def told_appender(told)
        appender = Object.new
        appender.define_singleton_method(:process_exiting=) { |exiting| told << exiting }
        appender.define_singleton_method(:should_log?) { |_log| false }
        appender
      end

      # Logs the entries to the appenders, as the thread that writes to every appender does.
      def log_entries(count)
        count.times do |i|
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = "entry #{i}"
          appenders.log(log)
        end
      end

      def discarded_reports
        capture_logger.events.select { |it| it.message.start_with?("Discarded") }
      end

      describe "an appender without a queue of its own, while the process exits" do
        let(:down) { DownAppender.new }
        let(:recording) { SemanticLogger::Test::CaptureLogEvents.new }

        before do
          appenders << down
          appenders << recording
        end

        it "is given no more messages once its destination fails, while the others are given every one" do
          appenders.process_exiting = true
          log_entries(5)

          assert_equal ["entry 0"], down.attempts
          assert_equal 5, recording.events.size
        end

        it "is reported at the flush, with the messages it was not given, then flushed" do
          reports = -> { discarded_reports.size }
          down.define_singleton_method(:flush) { flushes << reports.call }
          appenders.process_exiting = true
          log_entries(5)
          appenders.flush

          assert_equal [1], down.flushes, "it should be flushed once, after the report"
          report = discarded_reports.first

          assert_equal "Discarded 4 log message(s) during the flush at exit, after the destination failed, " \
                       "for appender: #{down.name}", report&.message
          assert_equal "destination unavailable", report.exception.message
        end

        it "is reported again only for the messages it was not given since" do
          appenders.process_exiting = true
          log_entries(3)
          appenders.flush
          appenders.flush
          log_entries(1)
          appenders.flush

          counts = discarded_reports.map { |it| it.message[/Discarded (\d+)/, 1].to_i }

          assert_equal [2, 1], counts
        end

        it "is written to again once the process no longer exits" do
          appenders.process_exiting = true
          log_entries(2)
          appenders.process_exiting = false
          log_entries(2)
          appenders.flush

          assert_equal ["entry 0", "entry 0", "entry 1"], down.attempts
          assert_equal [true], down.flushes
          assert_empty discarded_reports
        end

        it "is written to again the next time the process exits, until its destination fails again" do
          appenders.process_exiting = true
          log_entries(2)
          appenders.process_exiting = false
          appenders.process_exiting = true
          log_entries(2)

          assert_equal ["entry 0", "entry 0"], down.attempts
        end

        it "delivers at the flush the messages it accepted before it failed" do
          holding = HoldingAppender.new
          appenders << holding
          appenders.process_exiting = true
          log_entries(5)

          assert_empty holding.delivered
          appenders.flush

          assert_equal ["entry 0", "entry 1"], holding.delivered
          assert_includes discarded_reports.map(&:message),
                          "Discarded 2 log message(s) during the flush at exit, after the destination failed, " \
                          "for appender: #{holding.name}"
        end

        it "is given every message in a child process forked while the process exits" do
          skip "fork is not supported" unless Process.respond_to?(:fork)

          appenders.process_exiting = true
          reader, writer = IO.pipe
          pid            = fork do
            reader.close
            log_entries(3)
            appenders.flush
            writer.write("#{down.attempts.join(',')};#{discarded_reports.size}")
          ensure
            writer.close
            exit!(0)
          end
          writer.close
          Process.wait(pid)
          attempts, reports = reader.read.split(";")
          reader.close

          assert_equal "entry 0,entry 1,entry 2", attempts
          assert_equal "0", reports
        end

        it "is given every message while the process is not exiting" do
          log_entries(3)

          assert_equal ["entry 0", "entry 1", "entry 2"], down.attempts
        end

        it "is given every message when the content of a message failed" do
          down.define_singleton_method(:message_error?) { |_exception| true }
          appenders.process_exiting = true
          log_entries(3)

          assert_equal ["entry 0", "entry 1", "entry 2"], down.attempts
        end

        it "is given every message when its filter raised, rather than its destination failing" do
          written  = []
          filtered = Class.new(SemanticLogger::Subscriber) { define_method(:log) { |log| written << log.message } }.
                     new(filter: ->(log) { log.message == "entry 0" ? raise("filter boom") : true })
          appenders << filtered
          appenders.process_exiting = true
          log_entries(3)

          assert_equal ["entry 1", "entry 2"], written
        end
      end

      it "gives every message to an appender with a queue of its own, which is told itself" do
        attempts = []
        queued   = Object.new
        queued.define_singleton_method(:process_exiting=) { |_exiting| nil }
        queued.define_singleton_method(:name) { "Queued" }
        queued.define_singleton_method(:should_log?) { |_log| true }
        queued.define_singleton_method(:log) do |log|
          attempts << log.message
          raise IOError, "queue closed"
        end
        appenders << queued
        appenders.process_exiting = true
        log_entries(3)

        assert_equal ["entry 0", "entry 1", "entry 2"], attempts
      end

      describe "in a signal trap" do
        include SignalTrapHelper

        it "tells the appenders, and skips one whose destination fails" do
          told = []
          down = DownAppender.new
          appenders << told_appender(told)
          appenders << down
          in_signal_trap { appenders.process_exiting = true }
          log_entries(2)
          in_signal_trap { appenders.process_exiting = false }

          assert_equal [true, false], told
          assert_equal ["entry 0"], down.attempts
        end
      end

      it "tells each appender with a thread of its own, and skips the others" do
        told = []
        appenders << SemanticLogger::Test::CaptureLogEvents.new
        appenders << told_appender(told)

        appenders.process_exiting = true
        appenders.process_exiting = false

        assert_equal [true, false], told
      end

      it "does not call an exiting= that a custom appender defines for its own purpose" do
        custom = Class.new(SemanticLogger::Test::CaptureLogEvents) { attr_accessor :exiting }.new
        appenders << custom

        appenders.process_exiting = true

        assert_nil custom.exiting
      end

      # The flush at exit runs after the appenders are told, so it must still run.
      it "tells the remaining appenders when one raises, and reports it" do
        told    = []
        failing = Object.new
        failing.define_singleton_method(:process_exiting=) { |_exiting| raise "exiting boom" }
        failing.define_singleton_method(:name) { "Failing" }
        appenders << failing
        appenders << told_appender(told)

        appenders.process_exiting = true

        assert_equal [true], told
        report = capture_logger.events.find { |it| it.message.start_with?("Failed to tell appender") }

        assert_equal "exiting boom", report&.exception&.message
      end
    end
  end
end
