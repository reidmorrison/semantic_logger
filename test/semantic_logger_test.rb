require_relative "test_helper"

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
        SemanticLogger::Logger.subscribers.clear
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
      it "returns the size of the processor queue" do
        queue = Minitest::Mock.new
        queue.expect(:size, 7)
        processor = Minitest::Mock.new
        processor.expect(:queue, queue)

        SemanticLogger::Logger.stub(:processor, processor) do
          assert_equal 7, SemanticLogger.queue_size
        end

        processor.verify
        queue.verify
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
