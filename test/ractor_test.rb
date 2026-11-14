require_relative "test_helper"

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
      # returns the entries written meanwhile.
      def logs_from_ractor(*args, name: nil, &block)
        experimental           = Warning[:experimental]
        Warning[:experimental] = false
        ::Ractor.new(*args, name: name, &block).join
        SemanticLogger.flush
        collector.logs
      ensure
        Warning[:experimental] = experimental
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

      it "gives a Loggable class a logger of its own in the Ractor" do
        main_logger = Worker.logger
        log         = logs_from_ractor { SemanticLogger::RactorTest::Worker.new.work }.first

        assert_equal "Worker", log.message
        assert_equal "SemanticLogger::RactorTest::Worker", log.name
        assert_same main_logger, Worker.logger
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
          SemanticLogger::Logger.subscribers&.clear
          SemanticLogger::Logger.instance_variable_set(:@ractor_subscribers, nil)
        end

        it "calls only the shareable ones in the Ractor" do
          SemanticLogger.on_log { |log| log.set_context(:block, "not shareable") }
          SemanticLogger.on_log(MarkInRactor)
          log = logs_from_ractor { SemanticLogger["InRactor"].info("Subscribed") }.first

          assert_equal({subscriber: "shareable"}, log.context)
        end
      end

      it "flushes from the Ractor" do
        logs = logs_from_ractor do
          SemanticLogger["InRactor"].info("Before flush", flushed: SemanticLogger.flush)
        end

        assert logs.first.payload[:flushed]
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
  end
end
