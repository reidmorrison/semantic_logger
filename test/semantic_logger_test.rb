require_relative "test_helper"
require_relative "signal_trap_helper"
require_relative "forked_child_helper"

# A named class used as a logger cache key in the ".[]" tests.
class CachedSample
  include SemanticLogger::Loggable
end

class SemanticLoggerTest < Minitest::Test
  describe SemanticLogger do
    let(:logger) { SemanticLogger["TestLogger"] }

    describe ".[]" do
      after do
        SemanticLogger.cache_loggers = false
      end

      it "returns a new instance for a string" do
        refute_same SemanticLogger["MyClass"], SemanticLogger["MyClass"]
      end

      it "returns a new instance for a class when caching is disabled" do
        refute_predicate SemanticLogger, :cache_loggers?
        refute_same SemanticLogger[CachedSample], SemanticLogger[CachedSample]
      end

      describe "with caching enabled" do
        before do
          SemanticLogger.cache_loggers = true
        end

        it "returns the same instance for a class" do
          assert_same SemanticLogger[CachedSample], SemanticLogger[CachedSample]
        end

        it "still returns a new instance for a string" do
          refute_same SemanticLogger["MyClass"], SemanticLogger["MyClass"]
        end

        it "does not cache anonymous classes" do
          anonymous = Class.new

          refute_same SemanticLogger[anonymous], SemanticLogger[anonymous]
        end

        it "shares level changes across holders of the cached logger" do
          one = SemanticLogger[CachedSample]
          two = SemanticLogger[CachedSample]
          one.level = :trace

          assert_equal :trace, two.level
        ensure
          one&.level = nil
        end

        it "builds fresh instances after the cache is cleared" do
          first = SemanticLogger[CachedSample]
          SemanticLogger.clear_logger_cache

          refute_same first, SemanticLogger[CachedSample]
        end

        it "shares the cached logger with the Loggable mixin" do
          CachedSample.instance_variable_set(:@semantic_logger, nil)

          assert_same SemanticLogger[CachedSample], CachedSample.logger
        ensure
          CachedSample.instance_variable_set(:@semantic_logger, nil)
        end

        describe "in a signal trap, where adding to the cache would lock a Mutex" do
          include SignalTrapHelper

          it "returns a logger, which is cached by the time the trap returns" do
            SemanticLogger.clear_logger_cache
            logger = in_signal_trap { SemanticLogger[CachedSample] }

            assert_instance_of SemanticLogger::Logger, logger
            assert_same logger, SemanticLogger[CachedSample]
          end

          it "returns the logger already cached" do
            cached = SemanticLogger[CachedSample]

            in_trap = in_signal_trap { SemanticLogger[CachedSample] }

            assert_same cached, in_trap
          end
        end
      end

      it "clears the cache and returns fresh instances after disabling" do
        SemanticLogger.cache_loggers = true
        cached = SemanticLogger[CachedSample]
        SemanticLogger.cache_loggers = false

        refute_same cached, SemanticLogger[CachedSample]
      end
    end

    describe ".add_appender" do
      before do
        @appender = nil
      end

      after do
        SemanticLogger.remove_appender(@appender)
        FileUtils.rm_f("sample.log")
      end

      it "adds file appender" do
        @appender = SemanticLogger.add_appender(file_name: "sample.log")

        assert_kind_of SemanticLogger::Appender::File, @appender
        assert_includes SemanticLogger.appenders, @appender
        assert_kind_of SemanticLogger::Formatters::Default, @appender.formatter
      end
    end

    describe ".remove_appender" do
      # Records what happens to it, in order, and, once released, finishes writing each log message.
      let(:appender_class) do
        Class.new(SemanticLogger::Subscriber) do
          attr_reader :events, :writing, :release

          def initialize(...)
            super
            @events  = Queue.new
            @writing = Queue.new
            @release = Queue.new
          end

          def log(log)
            writing << log.message
            release.pop(timeout: 5)
            events << :written
          end

          def close
            events << :closed
            :closed
          end

          def recorded = Array.new(events.size) { events.pop }
        end
      end

      # Only the log messages of these tests, not those of the test reporter.
      let(:filter) { /\ARemoveAppenderTest\z/ }
      let(:appender) { appender_class.new(filter: filter) }
      let(:logger) { SemanticLogger["RemoveAppenderTest"] }

      after do
        appender.release << true
        SemanticLogger.remove_appender(appender) if SemanticLogger.appenders.include?(appender)
        SemanticLogger::Logger.clear_subscribers
        # Writes what this test logged, so that it cannot reach the appender of the next test.
        SemanticLogger.flush
      end

      it "waits for the log message being written to the appender before closing it" do
        SemanticLogger.add_appender(appender: appender)
        writer = Thread.new { logger.info("in flight") }

        assert_equal "in flight", appender.writing.pop(timeout: 5)

        remover = Thread.new { SemanticLogger.remove_appender(appender) }
        # Without waiting, it would close the appender before the release below.
        Thread.pass until %w[sleep].include?(remover.status) || !remover.alive?
        sleep 0.1
        appender.release << true

        assert remover.join(5), "remove_appender did not return"
        writer.join(5)

        assert_equal %i[written closed], appender.recorded
        refute_includes SemanticLogger.appenders, appender
      end

      it "returns the result of closing the appender" do
        appender.release << true
        SemanticLogger.add_appender(appender: appender)

        assert_equal :closed, SemanticLogger.remove_appender(appender)
      end

      it "closes an appender that removes itself as it writes, without waiting for itself" do
        remover = Class.new(appender_class) do
          def log(log)
            super
            SemanticLogger.remove_appender(self)
          end
        end.new(filter: filter)
        remover.release << true
        SemanticLogger.add_appender(appender: remover)
        logged = Thread.new do
          logger.info("remove me")
          SemanticLogger.flush
        end

        assert logged.join(5), "the appender waited for its own thread"
        assert_equal %i[written closed], remover.recorded
        refute_includes SemanticLogger.appenders, remover
      end

      it "removes an appender from an on_log subscriber" do
        appender.release << true
        SemanticLogger.add_appender(appender: appender)
        SemanticLogger.on_log { |log| SemanticLogger.remove_appender(appender) if log.message == "remove it" }
        logged = Thread.new { logger.info("remove it") }

        assert logged.join(5), "remove_appender did not return"
        assert_equal [:closed], appender.recorded
        refute_includes SemanticLogger.appenders, appender
      end
    end

    # As an appender added with async: true writes, on its worker thread, which the thread that writes to
    # every appender may be waiting for.
    describe "called on the worker thread of an appender added with async: true" do
      # Runs the block given to #on_write as it writes a log message of these tests.
      let(:caller_class) do
        Class.new(SemanticLogger::Subscriber) do
          def on_write(&block)
            @on_write = block
          end

          def log(_log)
            @on_write&.call
            true
          end
        end
      end

      let(:caller_appender) { caller_class.new(filter: /\AOnAppenderThreadTest\z/) }
      let(:results) { Queue.new }
      let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }

      before do
        @logger = SemanticLogger::Logger.processor.appenders.logger
        SemanticLogger::Logger.processor.appenders.logger = internal_logger
        # Created here, since a let is not thread-safe: the appender's worker thread and the test
        # could otherwise each create a Queue of their own on first use.
        results
      end

      after do
        SemanticLogger::Logger.processor.appenders.logger = @logger
        # Should the call wait forever, its thread is ended, so that the processor's thread no longer
        # waits for it, and the tests that follow do not wait either.
        @caller.processor.instance_variable_get(:@thread)&.kill&.join
        [@caller, @removed].each { |appender| SemanticLogger.remove_appender(appender) }
      end

      it "removes another appender, without waiting forever, and closes it" do
        closed   = Queue.new
        @removed = SemanticLogger.add_appender(io: StringIO.new)
        @removed.define_singleton_method(:close) { closed << true }
        caller_appender.on_write { results << SemanticLogger.remove_appender(@removed) }
        @caller = SemanticLogger.add_appender(appender: caller_appender, async: true)
        SemanticLogger["OnAppenderThreadTest"].info("remove now")

        assert results.pop(timeout: 5), "remove_appender did not return"
        SemanticLogger.flush

        refute_includes SemanticLogger.appenders, @removed
        assert closed.pop(timeout: 5), "the appender was not closed"
      end

      it "removes itself, then flushes, without waiting forever" do
        caller_appender.on_write do
          SemanticLogger.remove_appender(@caller)
          # Gives the processor's thread time to start closing the appender.
          sleep 0.1
          results << [SemanticLogger.flush]
        end
        @caller = SemanticLogger.add_appender(appender: caller_appender, async: true)
        SemanticLogger["OnAppenderThreadTest"].info("remove me")

        refute_nil results.pop(timeout: 5), "SemanticLogger.flush did not return"
        flushing = Thread.new { SemanticLogger.flush }

        assert flushing.join(5), "SemanticLogger.flush no longer returns"
        refute_includes SemanticLogger.appenders, @caller
      end

      it "flushes, returning without waiting forever" do
        caller_appender.on_write { results << [SemanticLogger.flush] }
        @caller = SemanticLogger.add_appender(appender: caller_appender, async: true)
        SemanticLogger["OnAppenderThreadTest"].info("flush now")

        refute_nil results.pop(timeout: 5), "SemanticLogger.flush did not return"
      end
    end

    describe ".remove_appender in a forked child" do
      include ForkedChildHelper

      # Holds a connection built in the process it names, such as a TLS connection. Its #reopen is
      # fork-aware: in a forked child, it forgets the connection the parent built, without closing
      # it, and builds its own. Its #close is not: it closes whatever connection it holds.
      let(:fork_aware_class) do
        Class.new(SemanticLogger::Subscriber) do
          attr_reader :connection, :closed

          def initialize(...)
            super
            @connection = "built by #{Process.pid}"
          end

          def log(_log) = true

          def batch(_logs) = true

          def reopen
            @connection = "built by #{Process.pid}" unless @connection == "built by #{Process.pid}"
          end

          def close
            @closed     = @connection
            @connection = nil
          end
        end
      end

      # In a forked child, its #reopen waits until released, so that the processor's worker thread is
      # still reopening the appenders when the child removes another one.
      let(:gate_class) do
        Class.new(SemanticLogger::Subscriber) do
          attr_reader :gate

          def initialize(...)
            super
            @parent = Process.pid
            @gate   = Queue.new
          end

          def log(_log) = true

          def reopen
            gate.pop(timeout: 5) unless Process.pid == @parent
          end
        end
      end

      # Only a processor with a worker thread reopens on that thread, after the fork, so only it has
      # a reopen pending; the synchronous one reopens in the fork itself, so it needs no gate, and
      # would wait for it there.
      let(:gate) do
        next unless SemanticLogger::Logger.processor.is_a?(SemanticLogger::Processor)

        SemanticLogger.add_appender(appender: gate_class.new)
      end
      let(:fork_aware) { fork_aware_class.new }

      before do
        skip "fork is not supported" unless Process.respond_to?(:fork) && Process.respond_to?(:_fork)
      end

      after do
        [@added, gate].each { |appender| SemanticLogger.remove_appender(appender) }
      end

      # Removes the appender in a forked child, while the processor's worker thread is still reopening
      # the appenders, and returns the connection that its #close closed there.
      def remove_in_child(added)
        gate
        in_forked_child do
          remover = Thread.new { SemanticLogger.remove_appender(added) }
          Thread.pass until %w[sleep].include?(remover.status) || !remover.alive?
          sleep 0.1
          gate&.gate&.push(true)

          assert remover.join(5), "remove_appender did not return"
          refute_includes SemanticLogger.appenders, added
          assert_equal "built by #{Process.pid}", fork_aware.closed, "it should close only what the child built"
          ""
        end
      end

      it "reopens the appender before closing it, so that it closes only what the child built" do
        @added = SemanticLogger.add_appender(appender: fork_aware)
        remove_in_child(@added)

        assert_equal "built by #{Process.pid}", fork_aware.connection, "the parent keeps its connection"
      end

      it "reopens an appender added with async: true before closing it" do
        @added = SemanticLogger.add_appender(appender: fork_aware, async: true)
        remove_in_child(@added)

        assert_equal "built by #{Process.pid}", fork_aware.connection, "the parent keeps its connection"
      end

      it "reopens an appender added in batches before closing it" do
        @added = SemanticLogger.add_appender(appender: fork_aware, batch: true)
        remove_in_child(@added)

        assert_equal "built by #{Process.pid}", fork_aware.connection, "the parent keeps its connection"
      end
    end

    describe ".tagged" do
      it "adds one tag" do
        events = semantic_logger_events do
          SemanticLogger.tagged("12345", "DJHSFK") do
            logger.info("Hello World")
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "Hello World",
          tags:    %w[12345 DJHSFK]
        )
      end

      it "add embedded tags" do
        events = semantic_logger_events do
          SemanticLogger.tagged("First Level", "tags") do
            SemanticLogger.tagged("Second Level") do
              logger.info("Hello World")
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "Hello World",
          tags:    ["First Level", "tags", "Second Level"]
        )
      end

      it "adds named tags" do
        events = semantic_logger_events do
          SemanticLogger.tagged(level1: 1) do
            assert_equal({level1: 1}, SemanticLogger.named_tags)
            SemanticLogger.tagged(level2: 2, more: "data") do
              assert_equal({level1: 1, level2: 2, more: "data"}, SemanticLogger.named_tags)
              SemanticLogger.tagged(level3: 3) do
                assert_equal({level1: 1, level2: 2, more: "data", level3: 3}, SemanticLogger.named_tags)
                logger.info("Hello World")
              end
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message:    "Hello World",
          named_tags: {level1: 1, level2: 2, more: "data", level3: 3}
        )
      end
    end

    describe ".named_tags" do
      it "named tags in creation order" do
        SemanticLogger.named_tagged(level1: 1) do
          assert_equal({level1: 1}, SemanticLogger.named_tags)
          SemanticLogger.named_tagged(level2: 2, more: "data") do
            assert_equal({level1: 1, level2: 2, more: "data"}, SemanticLogger.named_tags)
            SemanticLogger.named_tagged(level3: 3) do
              assert_equal({level1: 1, level2: 2, more: "data", level3: 3}, SemanticLogger.named_tags)
            end
          end
        end
      end
    end

    describe ".named_tagged" do
      it "logs named tags in creation order" do
        events = semantic_logger_events do
          SemanticLogger.named_tagged(level1: 1) do
            SemanticLogger.named_tagged(level2: 2, more: "data") do
              SemanticLogger.named_tagged(level3: 3) do
                logger.info("Hello World")
              end
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message:    "Hello World",
          named_tags: {level1: 1, level2: 2, more: "data", level3: 3}
        )
      end
    end

    describe ".fast_tag" do
      it "add string tag to log entries" do
        events = semantic_logger_events do
          logger.fast_tag("12345") do
            logger.info("Hello World")
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "Hello World",
          tags:    %w[12345]
        )
      end
    end

    describe ".default_level" do
      it "uses global default log level" do
        # Uses global default level since logger does not have one set
        SemanticLogger.stub(:default_level, :warn) do
          assert_equal :warn, logger.level
        end
      end

      it "logger retains explicit log level" do
        # Retains the explicit log level even when global log level is different
        logger.level = :trace

        SemanticLogger.stub(:default_level, :warn) do
          assert_equal :trace, logger.level
        end
      end
    end

    describe ".silence" do
      it "not log at a level below the default silence level" do
        events = semantic_logger_events(silence: false) do
          SemanticLogger.stub(:default_level, :info) do
            SemanticLogger.silence do
              logger.fatal("fatal")
              logger.error("error")
              logger.warn("warn")
              logger.info("info")
              logger.debug("debug")
              logger.trace("trace")
            end
          end
        end

        assert_equal %w[fatal error], events.map(&:message)
      end

      it "not log at a level below a specific silence level" do
        events = semantic_logger_events(silence: false) do
          SemanticLogger.stub(:default_level, :info) do
            SemanticLogger.silence(:info) do
              logger.fatal("fatal")
              logger.error("error")
              logger.warn("warn")
              logger.info("info")
              logger.debug("debug")
              logger.trace("trace")
            end
          end
        end

        assert_equal %w[fatal error warn info], events.map(&:message)
      end

      # it "default silence level is :error, so should log everything else" do
      it "silencer is ignored when logger has an explicit log level" do
        logger.level = :trace
        events       = semantic_logger_events(silence: false) do
          SemanticLogger.silence(:debug) do
            logger.fatal("fatal")
            logger.error("error")
            logger.warn("warn")
            logger.info("info")
            logger.debug("debug")
            logger.trace("trace")
          end
        end

        assert_equal %w[fatal error warn info debug trace], events.map(&:message)
      end

      it "log at a silence level below the default level" do
        events = semantic_logger_events(silence: false) do
          SemanticLogger.stub(:default_level, :info) do
            assert_equal :info, logger.level
            logger.silence(:debug) do
              logger.debug("hello world")
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "hello world",
          level:   :debug
        )
      end
    end

    describe ".flush, .close, and .reopen" do
      it "delegate to the processor" do
        mock = Minitest::Mock.new
        mock.expect(:flush, nil)
        mock.expect(:close, nil)
        mock.expect(:reopen, nil)
        # On Ruby 4.0, the flush first asks whether this thread is inside the processor (see
        # RactorReceiver.flush).
        def mock.current_thread_inside? = false

        # Clear the per-process reopen guard so reopen is not skipped.
        SemanticLogger.instance_variable_set(:@reopened_pid, nil)

        SemanticLogger::Logger.stub(:processor, mock) do
          SemanticLogger.flush
          SemanticLogger.close
          SemanticLogger.reopen
        end

        mock.verify
      end
    end

    # Runs the script in another Ruby, with this Semantic Logger, and returns what it printed, or fails
    # once it has not exited within 20 seconds. Its output is read as it is printed, so that it cannot
    # fill the pipe and block.
    def run_ruby(script)
      reader, writer = IO.pipe
      pid            = Process.spawn(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script,
                                     out: writer, err: writer)
      writer.close
      output = Thread.new { reader.read }
      waiter = Process.detach(pid)
      unless waiter.join(20)
        Process.kill("KILL", pid)

        flunk "the process should exit within 20 seconds"
      end

      assert_predicate waiter.value, :success?, output.value
      output.value
    ensure
      # Once the process has exited, the pipe is at its end.
      output&.join(5)
      reader&.close
    end

    # Semantic Logger flushes the appenders in an at_exit hook, so these exit another Ruby.
    describe "the flush at exit" do
      # Logs 30 entries to an appender added with async: true, whose destination is down, and to
      # another, then exits once the worker thread of the first backs off, holding its first entry,
      # its queue is full, and the thread that writes to every appender waits for room on it. Its
      # back-off is 31 seconds, longer than the test waits. Prints what happened at exit, as JSON,
      # from a hook that runs after Semantic Logger's.
      let(:script) do
        <<~RUBY
          require "json"
          state = {}
          at_exit do
            puts JSON.generate(
              seconds:             Process.clock_gettime(Process::CLOCK_MONOTONIC) - state[:exiting_at],
              attempts_after_exit: state[:down].attempts.size - state[:attempts_before_exit],
              failed:              state[:proxy].failed_count,
              written:             state[:healthy].events.size
            )
          end
          require "semantic_logger"
          require "semantic_logger/test/capture_log_events"

          class Down < SemanticLogger::Subscriber
            def attempts = @attempts ||= Queue.new

            def log(_log)
              attempts << true
              raise IOError, "destination unavailable"
            end

            def wrote_nothing?(_exception) = true
          end

          state[:down]        = Down.new
          state[:down].logger = SemanticLogger::Test::CaptureLogEvents.new
          state[:proxy]       = SemanticLogger.add_appender(appender: state[:down], async: true, max_queue_size: 2)
          state[:healthy]     = SemanticLogger::Test::CaptureLogEvents.new
          SemanticLogger.add_appender(appender: state[:healthy], async: true)
          state[:proxy].processor.instance_variable_get(:@backoff).instance_variable_set(:@retry_count, 30)

          30.times { |i| SemanticLogger["Exit"].info("entry \#{i}") }
          deadline = Time.now + 10
          Thread.pass until (state[:proxy].processor.retry_count == 31 && state[:proxy].queue.num_waiting == 1) ||
                            Time.now > deadline
          raise "the appender should be backing off, with the main worker waiting" unless state[:proxy].queue.num_waiting == 1

          state[:attempts_before_exit] = state[:down].attempts.size
          state[:exiting_at]           = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          exit
        RUBY
      end

      it "exits within seconds during an outage, discarding the queued entries after one more write fails" do
        result = JSON.parse(run_ruby(script).lines.last, symbolize_names: true)

        assert_operator result[:seconds], :<, 5
        assert_equal 1, result[:attempts_after_exit], "only the entry held should be written again"
        assert_equal 30, result[:failed]
        assert_equal 30, result[:written], "the other appender should write every entry"
      end

      # Logs 30 entries to a plain :http appender, without a queue of its own, whose server accepts
      # connections but never answers, and to another appender, then exits once the first request is
      # in flight. Each request would wait out the read_timeout of 1 second, so 30 seconds in all.
      # Prints what happened at exit, as JSON, from a hook that runs after Semantic Logger's.
      let(:synchronous_script) do
        <<~RUBY
          require "json"
          require "socket"
          state = {}
          at_exit do
            puts JSON.generate(
              seconds:  Process.clock_gettime(Process::CLOCK_MONOTONIC) - state[:exiting_at],
              requests: state[:requests].size,
              written:  state[:healthy].events.size,
              reports:  state[:internal].events.map(&:message)
            )
          end
          require "semantic_logger"
          require "semantic_logger/test/capture_log_events"

          # Accepts connections, and reads the requests, without ever answering one.
          server           = TCPServer.new("127.0.0.1", 0)
          state[:requests] = Queue.new
          Thread.new do
            loop do
              client = server.accept
              Thread.new(client) do |socket|
                loop { state[:requests] << true if socket.readpartial(65_536).include?("POST ") }
              rescue IOError, SystemCallError
                nil
              end
            end
          end

          state[:internal]                = SemanticLogger::Test::CaptureLogEvents.new
          SemanticLogger.appenders.logger = state[:internal]
          SemanticLogger.add_appender(appender: :http, url: "http://127.0.0.1:\#{server.addr[1]}/log", read_timeout: 1)
          state[:healthy] = SemanticLogger::Test::CaptureLogEvents.new
          SemanticLogger.add_appender(appender: state[:healthy])

          30.times { |i| SemanticLogger["Exit"].info("entry \#{i}") }
          deadline = Time.now + 10
          sleep(0.01) until !state[:requests].empty? || Time.now > deadline
          raise "the first request should be in flight" if state[:requests].empty?

          state[:exiting_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          exit
        RUBY
      end

      it "exits within seconds during an outage of an appender without a queue of its own, skipping it once it fails" do
        result = JSON.parse(run_ruby(synchronous_script).lines.last, symbolize_names: true)

        assert_operator result[:seconds], :<, 5
        assert_equal 1, result[:requests], "no request should be sent after the one that failed"
        assert_equal 30, result[:written], "the other appender should write every entry"
        assert_includes result[:reports],
                        "Discarded 29 log message(s) during the flush at exit, after the destination failed, " \
                        "for appender: SemanticLogger::Appender::Http"
      end
    end

    # The first log call of a process builds the processor, and its internal logger, so these log in
    # another Ruby.
    describe "the first log call of a process, made in a signal trap" do
      # Returns a script that runs the supplied code, then logs for the first time in a signal trap,
      # then adds an appender, and prints what happened, as JSON.
      def script(before_trap = "")
        <<~RUBY
          require "json"
          require "semantic_logger"
          #{before_trap}
          result = nil
          Signal.trap("USR1") do
            SemanticLogger["Trap"].info("First entry")
            result = "logged"
          rescue StandardError => e
            result = "\#{e.class}: \#{e.message}"
          end
          Process.kill("USR1", Process.pid)
          deadline = Time.now + 5
          sleep(0.01) until result || Time.now > deadline
          SemanticLogger.flush
          processed = SemanticLogger.stats[:processed]

          require "semantic_logger/test/capture_log_events"
          events = SemanticLogger::Test::CaptureLogEvents.new
          SemanticLogger.add_appender(appender: events)
          SemanticLogger["Trap"].info("After the trap")
          SemanticLogger.flush
          puts JSON.generate(result: result, processed: processed, written: events.events.map(&:message))
        RUBY
      end

      it "logs, rather than raise building the processor" do
        result = JSON.parse(run_ruby(script).lines.last, symbolize_names: true)

        assert_equal "logged", result[:result]
        assert_equal 1, result[:processed], "the entry should have reached the processor"
        assert_equal ["After the trap"], result[:written]
      end

      it "reports an on_log subscriber that raises, rather than raise writing the report" do
        output = run_ruby(script('SemanticLogger.on_log { |_log| raise "subscriber failed" }'))
        result = JSON.parse(output.lines.last, symbolize_names: true)

        assert_equal "logged", result[:result]
        assert_includes output, "Exception calling :on_log subscriber"
      end
    end

    describe ".sync! and .sync?" do
      it "switches the global processor to a SyncProcessor" do
        original = SemanticLogger::Logger.instance_variable_get(:@processor)
        begin
          SemanticLogger.sync!

          assert_predicate SemanticLogger, :sync?
          assert_kind_of SemanticLogger::SyncProcessor, SemanticLogger::Logger.processor
          # The appenders are carried over to the synchronous processor.
          assert_same original.appenders, SemanticLogger::Logger.processor.appenders if original
        ensure
          SemanticLogger::Logger.instance_variable_set(:@processor, original)
        end
      end
    end

    describe ".on_log" do
      after do
        # Clear on_log subscribers
        SemanticLogger::Logger.clear_subscribers
      end

      it "registers a log listener" do
        SemanticLogger.on_log do |log|
          log.set_context(:custom_info, "test")
        end

        events = semantic_logger_events do
          SemanticLogger.stub(:default_level, :info) do
            assert_equal :info, logger.level
            SemanticLogger.silence(:debug) do
              logger.debug("hello world")
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "hello world",
          context: {custom_info: "test"}
        )
      end

      it "reports an exception raised by a listener in sync mode, and still logs the entry" do
        internal  = InMemoryAppender.new
        appender  = InMemoryAppender.new
        processor = SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new(internal).tap { |a| a << appender })
        SemanticLogger.on_log { |_log| raise(ArgumentError, "listener failed") }

        SemanticLogger::Logger.stub(:processor, processor) do
          logger.info("hello world")
        end

        assert_equal "hello world", appender.message.message
        assert_equal "Exception calling :on_log subscriber", internal.message.message
        assert_kind_of ArgumentError, internal.message.exception
      end
    end

    describe ".host=" do
      it "overrides and returns the host" do
        original = SemanticLogger.host
        begin
          SemanticLogger.host = "my-host"

          assert_equal "my-host", SemanticLogger.host
        ensure
          SemanticLogger.host = original
        end
      end
    end

    describe ".application=" do
      it "overrides and returns the application" do
        original = SemanticLogger.application
        begin
          SemanticLogger.application = "My App"

          assert_equal "My App", SemanticLogger.application
        ensure
          SemanticLogger.application = original
        end
      end
    end

    describe ".environment=" do
      it "overrides and returns the environment" do
        original = SemanticLogger.environment
        begin
          SemanticLogger.environment = "staging"

          assert_equal "staging", SemanticLogger.environment
        ensure
          SemanticLogger.environment = original
        end
      end
    end

    describe ".backtrace_cleaner=" do
      after { SemanticLogger.backtrace_cleaner = nil }

      it "is nil by default" do
        assert_nil SemanticLogger.backtrace_cleaner
      end

      it "accepts an object that responds to #clean, or a Proc" do
        cleaner = Object.new
        def cleaner.clean(lines) = lines
        SemanticLogger.backtrace_cleaner = cleaner

        assert_same cleaner, SemanticLogger.backtrace_cleaner

        cleaner = ->(lines) { lines }
        SemanticLogger.backtrace_cleaner = cleaner

        assert_same cleaner, SemanticLogger.backtrace_cleaner
      end

      it "accepts a cleaner that does not define #nil?, such as a mock" do
        cleaner = Minitest::Mock.new.expect(:clean, [], [Array])
        SemanticLogger.backtrace_cleaner = cleaner

        assert_equal cleaner.__id__, SemanticLogger.backtrace_cleaner.__id__
      end

      it "accepts nil to stop cleaning backtraces" do
        SemanticLogger.backtrace_cleaner = ->(lines) { lines }
        SemanticLogger.backtrace_cleaner = nil

        assert_nil SemanticLogger.backtrace_cleaner
      end

      it "rejects a value that cannot clean a backtrace" do
        [true, "rails", :clean].each do |value|
          assert_raises(ArgumentError, value.inspect) { SemanticLogger.backtrace_cleaner = value }
        end
        assert_nil SemanticLogger.backtrace_cleaner
      end
    end

    describe ".safe_dimension_keys=" do
      after { SemanticLogger.safe_dimension_keys = [] }

      it "holds the keys as frozen Strings, once each, always with error.type" do
        assert_equal ["error.type"], SemanticLogger.safe_dimension_keys
        SemanticLogger.safe_dimension_keys |= [:"http.route", "http.route", +"url.scheme"]

        assert_equal %w[error.type http.route url.scheme], SemanticLogger.safe_dimension_keys
        assert_predicate SemanticLogger.safe_dimension_keys, :frozen?
        assert(SemanticLogger.safe_dimension_keys.all?(&:frozen?))
        SemanticLogger.safe_dimension_keys = []

        assert_equal ["error.type"], SemanticLogger.safe_dimension_keys
      end

      it "raises ArgumentError for a key that is not a String or Symbol" do
        error = assert_raises(ArgumentError) { SemanticLogger.safe_dimension_keys = [/route/] }

        assert_includes error.message, "String or Symbol"
      end
    end

    describe ".sensitive_keys=" do
      after { SemanticLogger.sensitive_keys = nil }

      it "is nil by default, with no redactor" do
        assert_nil SemanticLogger.sensitive_keys
        assert_nil SemanticLogger.redactor
      end

      it "returns the sensitive keys as supplied, and builds a redactor for them" do
        keys = %i[password token]
        SemanticLogger.sensitive_keys = keys

        assert_same keys, SemanticLogger.sensitive_keys
        assert_instance_of SemanticLogger::Redactor, SemanticLogger.redactor
        assert_same keys, SemanticLogger.redactor.sensitive_keys
      end

      it "accepts keys that do not define #nil?, such as a mock" do
        keys = Minitest::Mock.new.expect(:filter_param, nil, [String, nil])
        SemanticLogger.sensitive_keys = keys

        assert_equal keys.__id__, SemanticLogger.sensitive_keys.__id__
      end

      it "accepts nil to stop redacting" do
        SemanticLogger.sensitive_keys = [:password]
        SemanticLogger.sensitive_keys = nil

        assert_nil SemanticLogger.sensitive_keys
        assert_nil SemanticLogger.redactor
      end

      it "rejects any other value, keeping the sensitive keys it had" do
        keys = [:password]
        SemanticLogger.sensitive_keys = keys

        [true, "password", :password, [42]].each do |value|
          assert_raises(ArgumentError, value.inspect) { SemanticLogger.sensitive_keys = value }
        end

        assert_same keys, SemanticLogger.sensitive_keys
      end

      describe "when logging" do
        let(:appender) { InMemoryAppender.new }
        let(:mask) { SemanticLogger::Redactor::MASK }

        before do
          SemanticLogger.add_appender(appender: appender)
          SemanticLogger.sensitive_keys = %i[password authorization]
        end

        after do
          SemanticLogger.appenders.each { |appender| SemanticLogger.remove_appender(appender) }
          SemanticLogger::Logger.clear_subscribers
        end

        it "writes the entry with the values of the sensitive keys replaced" do
          payload = {user: "jack", password: "secret"}
          SemanticLogger.named_tagged(authorization: "Bearer abc") { logger.info("Login", payload) }
          SemanticLogger.flush

          assert_equal({user: "jack", password: mask}, appender.message.payload)
          assert_equal({authorization: mask}, appender.message.named_tags)
          assert_equal({user: "jack", password: "secret"}, payload)
        end

        it "redacts the context that an on_log subscriber adds, which receives the entry as logged" do
          seen = nil
          SemanticLogger.on_log do |log|
            seen = log.payload[:password]
            log.set_context(:request, {"Authorization" => "Bearer abc"})
          end
          logger.info("Login", password: "secret")
          SemanticLogger.flush

          assert_equal "secret", seen
          assert_equal({password: mask}, appender.message.payload)
          assert_equal({request: {"Authorization" => mask}}, appender.message.context)
        end

        it "redacts the dimensions of a metric" do
          logger.info(message: "Login", metric: "user/login", dimensions: {password: "x", region: "us"})
          SemanticLogger.flush

          assert_equal({password: mask, region: "us"}, appender.message.dimensions)
        end
      end
    end

    describe ".normalize_level" do
      it "returns the Symbol for every level that Semantic Logger accepts" do
        assert_equal :info, SemanticLogger.normalize_level(:info)
        assert_equal :warn, SemanticLogger.normalize_level("warn")
        assert_equal :warn, SemanticLogger.normalize_level("WARN")
        assert_equal :info, SemanticLogger.normalize_level(::Logger::INFO)
        assert_equal :error, SemanticLogger.normalize_level(::Logger::UNKNOWN)
      end

      it "raises ArgumentError for nil and for a level it does not know" do
        [nil, :inf, "verbose", 99, Object.new].each do |level|
          error = assert_raises(ArgumentError) { SemanticLogger.normalize_level(level) }
          assert_includes error.message, "Invalid level:#{level.inspect}"
        end
      end
    end

    describe ".call_site?" do
      after { SemanticLogger.call_site_level = nil }

      it "is true at and above call_site_level" do
        SemanticLogger.call_site_level = :info

        refute SemanticLogger.call_site?(:debug)
        assert SemanticLogger.call_site?(:info)
        assert SemanticLogger.call_site?("ERROR")
        assert SemanticLogger.call_site?(::Logger::WARN)
      end

      it "is false at every level while call sites are not recorded" do
        SemanticLogger.call_site_level = nil

        refute SemanticLogger.call_site?(:fatal)
      end

      it "raises ArgumentError for nil and for a level it does not know" do
        assert_raises(ArgumentError) { SemanticLogger.call_site?(nil) }
        assert_raises(ArgumentError) { SemanticLogger.call_site?(:inf) }
      end
    end

    describe ".backtrace?" do
      after { SemanticLogger.backtrace_level = :error }

      it "is true at and above backtrace_level" do
        SemanticLogger.backtrace_level = :warn

        refute SemanticLogger.backtrace?(:info)
        assert SemanticLogger.backtrace?(:warn)
        assert SemanticLogger.backtrace?("FATAL")
        assert SemanticLogger.backtrace?(::Logger::ERROR)
      end

      it "is false at every level while backtraces are not captured" do
        SemanticLogger.backtrace_level = nil

        refute SemanticLogger.backtrace?(:fatal)
      end

      it "raises ArgumentError for nil and for a level it does not know" do
        assert_raises(ArgumentError) { SemanticLogger.backtrace?(nil) }
        assert_raises(ArgumentError) { SemanticLogger.backtrace?(:inf) }
      end
    end

    describe ".application_backtrace" do
      it "starts at the code that calls it" do
        line      = __LINE__ + 1
        backtrace = SemanticLogger.application_backtrace

        assert_kind_of Array, backtrace
        assert backtrace.all?(String)
        assert_match(/\A#{Regexp.escape(__FILE__)}:#{line}:/, backtrace.first)
      end

      it "leaves out Semantic Logger's own frames" do
        refute(SemanticLogger.application_backtrace.any? { |frame| frame.include?("lib/semantic_logger/") })
      end
    end

    describe ".internal_logger=" do
      before do
        @processor_logger      = SemanticLogger::Processor.logger
        @sync_processor_logger = SemanticLogger::SyncProcessor.logger
      end

      after do
        SemanticLogger::Processor.logger     = @processor_logger
        SemanticLogger::SyncProcessor.logger = @sync_processor_logger
      end

      it "is the internal logger of both processors" do
        appender                       = SemanticLogger::Appender::IO.new(StringIO.new)
        SemanticLogger.internal_logger = appender

        assert_same appender, SemanticLogger.internal_logger
        assert_same appender, SemanticLogger::Processor.logger
        assert_same appender, SemanticLogger::SyncProcessor.logger
      end

      it "is what an appender added afterwards reports to" do
        output                         = StringIO.new
        SemanticLogger.internal_logger = SemanticLogger::Appender::IO.new(output)

        SemanticLogger::Appender::IO.new(StringIO.new).logger.warn("Could not connect")

        assert_includes output.string, "Could not connect"
      end

      it "wraps a Ruby Logger" do
        output                         = StringIO.new
        SemanticLogger.internal_logger = ::Logger.new(output)

        assert_kind_of SemanticLogger::Appender::Wrapper, SemanticLogger.internal_logger
        SemanticLogger.internal_logger.warn("Could not connect")

        assert_includes output.string, "Could not connect"
      end

      it "restores the default for nil" do
        SemanticLogger.internal_logger = SemanticLogger::Appender::IO.new(StringIO.new)
        SemanticLogger.internal_logger = nil

        assert_kind_of SemanticLogger::Appender::IO, SemanticLogger.internal_logger
        assert_equal "SemanticLogger::Processor", SemanticLogger.internal_logger.name
        assert_equal :warn, SemanticLogger.internal_logger.level
      end

      it "raises ArgumentError for a SemanticLogger::Logger" do
        assert_raises(ArgumentError) { SemanticLogger.internal_logger = SemanticLogger["Test"] }
      end
    end

    describe ".call_site_level=" do
      after { SemanticLogger.call_site_level = nil }

      it "is nil by default, with an index that no level reaches" do
        assert_nil SemanticLogger.call_site_level
        assert_operator SemanticLogger.call_site_level_index, :>, SemanticLogger::Levels.index(:fatal)
      end

      it "sets the level and its index" do
        SemanticLogger.call_site_level = :info

        assert_equal :info, SemanticLogger.call_site_level
        assert_equal SemanticLogger::Levels.index(:info), SemanticLogger.call_site_level_index
      end

      it "stores a level supplied as a String as its Symbol" do
        SemanticLogger.call_site_level = "warn"

        assert_equal :warn, SemanticLogger.call_site_level
      end

      it "accepts nil to stop recording call sites" do
        SemanticLogger.call_site_level = :info
        SemanticLogger.call_site_level = nil

        assert_nil SemanticLogger.call_site_level
        assert_operator SemanticLogger.call_site_level_index, :>, SemanticLogger::Levels.index(:fatal)
      end

      it "rejects an invalid level, keeping the current one" do
        SemanticLogger.call_site_level = :info

        assert_raises(ArgumentError) { SemanticLogger.call_site_level = :verbose }
        assert_equal :info, SemanticLogger.call_site_level
      end
    end

    describe ".call_site_skip_paths=" do
      after { SemanticLogger.call_site_skip_paths = nil }

      it "is empty by default" do
        assert_empty SemanticLogger.call_site_skip_paths
      end

      it "stores frozen copies, leaving the Strings supplied as they are" do
        path = +"app/lib/audit_log.rb"
        SemanticLogger.call_site_skip_paths = [path]

        assert_equal ["app/lib/audit_log.rb"], SemanticLogger.call_site_skip_paths
        assert_predicate SemanticLogger.call_site_skip_paths, :frozen?
        assert_predicate SemanticLogger.call_site_skip_paths.first, :frozen?
        refute_predicate path, :frozen?
      end

      it "accepts nil to skip only Semantic Logger's own frames" do
        SemanticLogger.call_site_skip_paths = ["app/lib/audit_log.rb"]
        SemanticLogger.call_site_skip_paths = nil

        assert_empty SemanticLogger.call_site_skip_paths
      end

      it "rejects a value that is not an Array of non-empty Strings" do
        ["app/lib", [:app], [""], [nil]].each do |value|
          assert_raises(ArgumentError, value.inspect) { SemanticLogger.call_site_skip_paths = value }
        end
        assert_empty SemanticLogger.call_site_skip_paths
      end
    end

    describe ".clear_appenders!" do
      it "closes the processor" do
        mock = Minitest::Mock.new
        mock.expect(:close, nil)

        SemanticLogger::Logger.stub(:processor, mock) do
          SemanticLogger.clear_appenders!
        end

        mock.verify
      end
    end

    describe ".queue_size" do
      include SignalTrapHelper

      it "returns the size of the processor queue" do
        processor = Minitest::Mock.new
        processor.expect(:queue_size, 7)

        SemanticLogger::Logger.stub(:processor, processor) do
          assert_equal 7, SemanticLogger.queue_size
        end

        processor.verify
      end

      it "returns the entries waiting with sync!" do
        processor = SemanticLogger::SyncProcessor.new
        SemanticLogger::Logger.stub(:processor, processor) do
          assert_equal 0, SemanticLogger.queue_size

          # Left by a signal trap, with no thread started to write it.
          processor.stub(:start_runner, nil) do
            in_signal_trap { processor.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "x" }) }
          end

          assert_equal 1, SemanticLogger.queue_size
        end
      end
    end

    describe ".stats" do
      it "delegates to the processor" do
        expected  = {queue_size: 0, processed: 5, dropped: 0, appenders: []}
        processor = Minitest::Mock.new
        processor.expect(:stats, expected)

        SemanticLogger::Logger.stub(:processor, processor) do
          assert_equal expected, SemanticLogger.stats
        end

        processor.verify
      end
    end

    describe ".lag_check_interval" do
      it "reads and writes the value via the processor" do
        processor = Minitest::Mock.new
        processor.expect(:lag_check_interval, 1_000)
        processor.expect(:lag_check_interval=, nil, [2_000])
        processor.expect(:lag_threshold_s, 30)

        SemanticLogger::Logger.stub(:processor, processor) do
          assert_equal 1_000, SemanticLogger.lag_check_interval
          SemanticLogger.lag_check_interval = 2_000

          assert_equal 30, SemanticLogger.lag_threshold_s
        end

        processor.verify
      end
    end

    describe ".non_blocking" do
      it "reads and writes the value via the processor" do
        processor = Minitest::Mock.new
        processor.expect(:non_blocking=, nil, [true])
        processor.expect(:non_blocking?, true)

        SemanticLogger::Logger.stub(:processor, processor) do
          SemanticLogger.non_blocking = true

          assert_predicate SemanticLogger, :non_blocking?
        end

        processor.verify
      end
    end

    describe ".add_signal_handler" do
      # Capture the blocks registered with Signal.trap instead of actually
      # installing handlers, so they can be invoked directly.
      def capture_signal_handlers(*args)
        traps = {}

        Signal.stub(:trap, ->(signal, &block) { traps[signal] = block }) do
          assert_equal true, SemanticLogger.add_signal_handler(*args)
        end
        traps
      end

      it "registers the default log level and thread dump handlers" do
        traps = capture_signal_handlers

        assert traps.key?("USR2"), "Expected a USR2 (log level) handler"
        assert traps.key?("TTIN"), "Expected a TTIN (thread dump) handler"
      end

      it "rotates to a more detailed level on the log level signal" do
        traps    = capture_signal_handlers
        original = SemanticLogger.default_level
        begin
          SemanticLogger.default_level = :info
          semantic_logger_events { traps["USR2"].call }
          # :info rotates one step more detailed to :debug
          assert_equal :debug, SemanticLogger.default_level
        ensure
          SemanticLogger.default_level = original
        end
      end

      it "wraps around to :fatal from :trace on the log level signal" do
        traps    = capture_signal_handlers
        original = SemanticLogger.default_level
        begin
          SemanticLogger.default_level = :trace
          semantic_logger_events { traps["USR2"].call }

          assert_equal :fatal, SemanticLogger.default_level
        ensure
          SemanticLogger.default_level = original
        end
      end

      it "logs a thread dump on the thread dump signal" do
        traps  = capture_signal_handlers
        events = semantic_logger_events do
          traps["TTIN"].call
        end

        assert_operator events.size, :>=, 1, "Expected at least one backtrace log event"
        assert_semantic_logger_event(events.first, name: "Thread Dump")
      end

      it "does not register a handler that is set to nil" do
        traps = capture_signal_handlers(nil, "TTIN")

        refute traps.key?("USR2"), "Did not expect a USR2 handler"
        assert traps.key?("TTIN"), "Expected a TTIN handler"
      end
    end
  end
end
