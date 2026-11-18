require_relative "test_helper"
require_relative "signal_trap_helper"
require "timeout"

module SemanticLogger
  # Logging from Ractors other than the main one (experimental, Ruby 4.0 and later).
  class RactorTest < Minitest::Test
    # Collects the log entries written to it, from any thread.
    class Collector < SemanticLogger::Subscriber
      def initialize(**)
        super
        @logs = Queue.new
      end

      def log(log)
        @logs << log
        true
      end

      # Returns [Array<Log>] the entries collected so far.
      def logs
        list = []
        list << @logs.pop until @logs.empty?
        list
      end
    end

    # A shareable on_log subscriber.
    module MarkInRactor
      def self.call(log)
        log.set_context(:subscriber, "shareable")
      end
    end

    # An exception that cannot be copied to another Ractor, since it holds a Proc.
    class HoldingError < StandardError
      def initialize(message = "holds a Proc")
        super
        @callback = -> { 1 }
      end
    end

    # An exception that cannot be copied to another Ractor, whose message needs its other data.
    class CodedError < StandardError
      def initialize
        super("Failed")
        @details = {code: 42, retry: -> { 1 }}
      end

      def message
        "#{super} with code #{@details.fetch(:code)}"
      end
    end

    # An exception that cannot be copied to another Ractor, whose message needs its cause.
    class WrapError < StandardError
      def initialize(message = "Wrapped")
        super
        @retry = -> { 1 }
      end

      def message
        "#{super}: #{cause&.message}"
      end
    end

    describe "Logging from a Ractor" do
      # Only the entries from the tests' loggers, not those of the test reporter.
      let(:collector) { Collector.new(level: :trace, filter: /\A(InRactor|SemanticLogger::RactorTest)/) }

      before do
        skip "Logging from a Ractor requires Ruby 4.0" unless defined?(::Ractor::Port)

        SemanticLogger.default_level = :trace
        SemanticLogger.add_appender(appender: collector)
      end

      after do
        SemanticLogger.remove_appender(collector)
      end

      # Runs the block in a new Ractor, without Ruby's warning that Ractors are experimental, and
      # returns its value.
      def in_ractor(*args, name: nil, &block)
        experimental           = Warning[:experimental]
        Warning[:experimental] = false
        ::Ractor.new(*args, name: name, &block).value
      ensure
        Warning[:experimental] = experimental
      end

      # Runs the block in a new Ractor, and returns the entries written meanwhile.
      def logs_from_ractor(*args, name: nil, &block)
        in_ractor(*args, name: name, &block)
        SemanticLogger.flush
        collector.logs
      end

      it "writes the entries to the appenders of the main Ractor" do
        logs = logs_from_ractor(name: "worker") do
          SemanticLogger.tagged("job") do
            SemanticLogger.tagged(job_id: 7) { SemanticLogger["InRactor"].info("Hello", user: "jack") }
          end
        end
        log = logs.find { |entry| entry.message == "Hello" }

        assert log, "Entry not written"
        assert_equal "InRactor", log.name
        assert_equal ["job"], log.tags
        assert_equal({job_id: 7}, log.named_tags)
        assert_equal({user: "jack"}, log.payload)
        assert_match %r{\Aworker/}, log.thread_name
      end

      it "names an unnamed Ractor by its number" do
        log = logs_from_ractor { SemanticLogger["InRactor"].info("Unnamed") }.first

        assert_match %r{\Aractor-\d+/}, log.thread_name
      end

      it "writes an exception with its cause and backtraces" do
        log = logs_from_ractor do
          begin
            raise ArgumentError, "inner"
          rescue ArgumentError
            raise IOError, "outer"
          end
        rescue IOError => e
          SemanticLogger["InRactor"].error("Failed", e)
        end.first

        assert_instance_of IOError, log.exception
        refute_empty log.exception.backtrace
        assert_instance_of ArgumentError, log.exception.cause
        refute_empty log.exception.cause.backtrace
      end

      it "replaces a payload value that cannot be copied with its inspect" do
        log = logs_from_ractor { SemanticLogger["InRactor"].info("Callback", callback: -> { 1 }, user: "jack") }.first

        assert_match(/\A#<Proc:/, log.payload[:callback])
        assert_equal "jack", log.payload[:user]
      end

      it "replaces an exception that cannot be copied with a plain one of the same class" do
        log = logs_from_ractor do
          raise SemanticLogger::RactorTest::HoldingError
        rescue SemanticLogger::RactorTest::HoldingError => e
          SemanticLogger["InRactor"].error("Failed", e)
        end.first

        assert_instance_of HoldingError, log.exception
        assert_equal "holds a Proc", log.exception.message
        refute_empty log.exception.backtrace
      end

      it "names the anonymous class of an exception whose message needs what cannot be copied" do
        log = logs_from_ractor do
          error_class = Class.new(StandardError) do
            def initialize(message = "needs its callback")
              super
              @callback = -> { "code 7" }
            end

            def message = "#{super} (#{@callback.call})"
          end
          raise error_class
        rescue StandardError => e
          SemanticLogger["InRactor"].error("Failed", e)
        end.first

        assert_instance_of RuntimeError, log.exception
        assert_match(/\A#<Class:0x\h+>: needs its callback \(code 7\)\z/, log.exception.message)
      end

      it "keeps the instance variables that the message of an exception that cannot be copied needs" do
        log = logs_from_ractor do
          raise SemanticLogger::RactorTest::CodedError
        rescue SemanticLogger::RactorTest::CodedError => e
          SemanticLogger["InRactor"].error("Failed", e)
        end.first

        assert_instance_of CodedError, log.exception
        assert_equal "Failed with code 42", log.exception.message
      end

      it "keeps the cause that the message of an exception that cannot be copied needs" do
        log = logs_from_ractor do
          begin
            raise ArgumentError, "bad input"
          rescue ArgumentError
            raise SemanticLogger::RactorTest::WrapError
          end
        rescue SemanticLogger::RactorTest::WrapError => e
          SemanticLogger["InRactor"].error("Failed", e)
        end.first

        assert_instance_of WrapError, log.exception
        assert_equal "Wrapped: bad input", log.exception.message
        assert_instance_of ArgumentError, log.exception.cause
      end

      it "gives a Loggable class a logger of its own in the Ractor" do
        main_logger = Worker.logger
        log         = logs_from_ractor { SemanticLogger::RactorTest::Worker.new.work }.first

        assert_equal "Worker", log.message
        assert_equal "SemanticLogger::RactorTest::Worker", log.name
        assert_same main_logger, Worker.logger
      end

      it "gives a class that extends a Loggable module a logger of its own in the Ractor" do
        main_logger = ExtendedWorker.logger
        log         = logs_from_ractor { SemanticLogger::RactorTest::ExtendedWorker.work }.first

        assert_equal "ExtendedWorker", log.message
        assert_equal "SemanticLogger::RactorTest::ExtendedWorker", log.name
        assert_same main_logger, ExtendedWorker.logger
      end

      it "replaces the logger of a class that extends a Loggable module in the Ractor only" do
        main_logger = ExtendedWorker.logger
        log         = logs_from_ractor do
          SemanticLogger::RactorTest::ExtendedWorker.logger = SemanticLogger["InRactorReplaced"]
          SemanticLogger::RactorTest::ExtendedWorker.work
        end.first

        assert_equal "InRactorReplaced", log.name
        assert_same main_logger, ExtendedWorker.logger
      end

      it "gives an instance of a class that includes a Loggable module a logger in the Ractor" do
        log = logs_from_ractor { SemanticLogger::RactorTest::IncludedWorker.new.work }.first

        assert_equal "SemanticLogger::RactorTest::IncludedWorker", log.name
      end

      it "caches loggers in the Ractor" do
        SemanticLogger.cache_loggers = true
        logs = logs_from_ractor do
          same = SemanticLogger[SemanticLogger::RactorTest::Worker].equal?(SemanticLogger[SemanticLogger::RactorTest::Worker])
          SemanticLogger["InRactor"].info("Cached", same: same)
        end

        assert logs.first.payload[:same]
      ensure
        SemanticLogger.cache_loggers = false
      end

      it "applies a context handed to the Ractor" do
        context = SemanticLogger.tagged("request") { SemanticLogger.tagged(request_id: 42) { SemanticLogger.context } }
        log     = logs_from_ractor(context) do |ctx|
          SemanticLogger.with_context(ctx) { SemanticLogger["InRactor"].info("Handed over") }
        end.first

        assert_equal ["request"], log.tags
        assert_equal({request_id: 42}, log.named_tags)
      end

      describe "on_log subscribers" do
        after do
          SemanticLogger::Logger.clear_subscribers
        end

        it "calls only the shareable ones in the Ractor" do
          SemanticLogger.on_log { |log| log.set_context(:block, "not shareable") }
          SemanticLogger.on_log(MarkInRactor)
          log = logs_from_ractor { SemanticLogger["InRactor"].info("Subscribed") }.first

          assert_equal({subscriber: "shareable"}, log.context)
        end
      end

      it "writes the entries of the Ractor by the time its flush returns" do
        in_ractor do
          SemanticLogger["InRactor"].info("Before flush")
          SemanticLogger.flush
        end

        assert_equal ["Before flush"], collector.logs.map(&:message)
      end

      describe "reopened in a signal trap, where Ruby does not allow a Mutex to be locked" do
        include SignalTrapHelper

        it "keeps the receiving thread" do
          receiver = RactorReceiver.instance_variable_get(:@thread)
          reopened = in_signal_trap { RactorReceiver.reopen }

          assert_nil reopened
          assert_same receiver, RactorReceiver.instance_variable_get(:@thread)
          logs = logs_from_ractor { SemanticLogger["InRactor"].info("After the reopen") }

          assert_equal ["After the reopen"], logs.map(&:message)
        end

        it "starts the receiving thread again once it has stopped, just after the trap" do
          receiver = RactorReceiver.instance_variable_get(:@thread)
          receiver.kill
          receiver.join

          refute_predicate RactorReceiver, :running?
          reopened = in_signal_trap { RactorReceiver.reopen }

          assert_nil reopened
          deadline = Time.now + 5
          sleep(0.01) until RactorReceiver.running? || Time.now > deadline

          assert_predicate RactorReceiver, :running?
          refute_same receiver, RactorReceiver.instance_variable_get(:@thread)
          logs = logs_from_ractor { SemanticLogger["InRactor"].info("After the restart") }

          assert_equal ["After the restart"], logs.map(&:message)
        end
      end

      it "flushes, rather than waiting on the receiving thread, while the process forks" do
        flushed = Timeout.timeout(10) { RactorReceiver.pause { SemanticLogger.flush } }

        refute_nil flushed
      end

      it "lets Ruby reject a fork in a Ractor" do
        message = in_ractor do
          fork { exit!(0) }
        rescue StandardError => e
          e.message
        end

        assert_match(/fork/, message)
      end

      it "writes the entries of a Ractor that did not flush" do
        logs = logs_from_ractor { 3.times { |i| SemanticLogger["InRactor"].info("Entry #{i}") } }

        assert_equal ["Entry 0", "Entry 1", "Entry 2"], logs.map(&:message)
      end

      it "only lets the main Ractor add an appender" do
        logs = logs_from_ractor do
          SemanticLogger.add_appender(io: $stdout)
        rescue ::Ractor::IsolationError => e
          SemanticLogger["InRactor"].info("Rejected", error: e.message)
        end

        assert_match(/only be configured in the main Ractor/, logs.first.payload[:error])
      end

      it "pauses receiving while the block forks, and writes the entries sent meanwhile afterwards" do
        experimental           = Warning[:experimental]
        Warning[:experimental] = false
        receiver               = RactorReceiver.instance_variable_get(:@thread)
        written                = RactorReceiver.pause do
          ::Ractor.new { SemanticLogger["InRactor"].info("During the pause") }.join
          sleep 0.01 until receiver.status == "sleep"
          collector.logs
        end
        SemanticLogger.flush

        assert_empty written
        assert_equal ["During the pause"], collector.logs.map(&:message)
      ensure
        Warning[:experimental] = experimental
      end

      it "logs from a Ractor in a forked child process" do
        skip "fork is not supported" unless Process.respond_to?(:fork)

        reader, writer = IO.pipe
        pid            = fork do
          reader.close
          logs = logs_from_ractor { SemanticLogger["InRactor"].info("In the child") }
          writer.write(logs.map(&:message).join(","))
          writer.close
          exit!(0)
        end
        writer.close
        Process.wait(pid)
        output = reader.read
        reader.close

        assert_equal "In the child", output
      end
    end

    # A class that logs with Loggable.
    class Worker
      include SemanticLogger::Loggable

      def work
        logger.info("Worker")
      end
    end

    # A module that logs with Loggable.
    module Working
      include SemanticLogger::Loggable

      def work
        logger.info(instance_of?(Class) ? name.split("::").last : "IncludedWorker")
      end
    end

    # A class that extends a module that logs with Loggable.
    class ExtendedWorker
      extend Working
    end

    # A class that includes a module that logs with Loggable, without including Loggable itself.
    class IncludedWorker
      include Working
    end
  end
end
