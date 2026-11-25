require_relative "test_helper"
require "stringio"
require "tmpdir"
require_relative "signal_trap_helper"

class SubscriberTest < Minitest::Test
  class SimpleSubscriber < SemanticLogger::Subscriber
    attr_accessor :event, :message

    def log(log)
      self.message = formatter.call(log, self) << "\n"
      self.event   = log
      true
    end
  end

  describe SemanticLogger::Subscriber do
    let(:appender) { SimpleSubscriber.new }
    let(:hash_value) { {session_id: "HSSKLEU@JDK767", tracking_number: 12_345} }
    let(:hash_str) { Regexp.escape(hash_value.inspect) }
    let(:file_name_reg_exp) { ' subscriber_test.rb:\d+' }

    # Shared prefix of a formatted log line: "<time> <level> [<pid>:<thread> <file>:<line>] <name>".
    let :log_prefix do
      /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:\w+#{file_name_reg_exp}\] SubscriberTest::SimpleSubscriber/
    end

    # Same prefix but without a captured file name (when the backtrace level is not met).
    let :log_prefix_no_file do
      /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:\w+\] SubscriberTest::SimpleSubscriber/
    end

    describe "format logs into text form" do
      it "handle no message or payload" do
        appender.debug

        assert_match(
          /#{log_prefix}\n/, appender.message
        )
      end

      it "handle message" do
        appender.debug "hello world"

        assert_match(
          /#{log_prefix} -- hello world\n/, appender.message
        )
      end

      it "handle message and payload" do
        appender.debug "hello world", hash_value

        assert_match(
          /#{log_prefix} -- hello world -- #{hash_str}\n/, appender.message
        )
      end

      it "handle message, payload, and exception" do
        appender.debug "hello world", hash_value, StandardError.new("StandardError")

        assert_match(
          /#{log_prefix} -- hello world -- #{hash_str} -- Exception: StandardError: StandardError\n\z/, appender.message
        )
      end

      it "logs exception with nil backtrace" do
        appender.debug StandardError.new("StandardError")

        assert_match(
          /#{log_prefix} -- Exception: StandardError: StandardError\n\z/, appender.message
        )
      end

      it "handle nested exception" do
        begin
          raise StandardError, "FirstError"
        rescue Exception
          begin
            raise StandardError, "SecondError"
          rescue Exception => e
            appender.debug e
          end
        end

        assert_match(
          /#{log_prefix} -- Exception: StandardError: SecondError\n/, appender.message
        )
        if Exception.instance_methods.include?(:cause)
          assert_match(/^Cause: StandardError: FirstError\n/,
                       appender.message)
        end
      end

      it "logs exception with empty backtrace" do
        exc = StandardError.new("StandardError")
        exc.set_backtrace([])
        appender.debug exc

        assert_match(
          /#{log_prefix} -- Exception: StandardError: StandardError\n\z/, appender.message
        )
      end

      it "ignores metric only messages" do
        appender.debug metric: "my/custom/metric"

        assert_nil appender.message
      end

      it "ignores metric only messages with payload" do
        appender.debug metric: "my/custom/metric", payload: {hello: :world}

        assert_nil appender.message
      end
    end

    describe "for each log level" do
      # Ensure that any log level can be logged
      SemanticLogger::LEVELS.each do |level|
        it "log #{level} with file_name" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            appender.send(level, "hello world", hash_value)

            assert_match(
              /#{log_prefix} -- hello world -- #{hash_str}\n/, appender.message
            )
          end
        end

        it "log #{level} without file_name" do
          SemanticLogger.stub(:backtrace_level_index, 100) do
            appender.send(level, "hello world", hash_value)

            assert_match(
              /#{log_prefix_no_file} -- hello world -- #{hash_str}\n/, appender.message
            )
          end
        end
      end
    end

    describe "custom formatter" do
      let :appender do
        SubscriberTest::SimpleSubscriber.new do |log|
          tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags&.size&.positive?

          message = log.message.to_s
          message << " -- " << log.payload.inspect if log.payload
          if log.exception
            message << " -- " << "#{log.exception.class}: #{log.exception.message}\n" \
                                 "#{(log.exception.backtrace || []).join("\n")}"
          end

          duration_str = log.duration ? " (#{format('%.1f', log.duration)}ms)" : ""

          formatted_time = log.time.strftime(SemanticLogger::Formatters::Base.build_time_format)

          "#{formatted_time} #{log.level.to_s.upcase} [#{$$}:#{log.thread_name}] " \
            "#{tags}#{log.name} -- #{message}#{duration_str}"
        end
      end

      it "format using formatter" do
        appender.debug

        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ DEBUG \[\d+:\w+\] SubscriberTest::SimpleSubscriber -- \n/,
                     appender.message)
      end
    end

    describe "#level" do
      it "logs everything when no level is set, ignoring the global default level" do
        original                     = SemanticLogger.default_level
        SemanticLogger.default_level = :error

        assert_equal :trace, appender.level
        assert_predicate appender, :trace?
      ensure
        SemanticLogger.default_level = original
      end

      it "uses the level from an enclosing with_level block" do
        appender.with_level(:warn) do
          assert_equal :warn, appender.level
          refute_predicate appender, :info?
        end

        assert_equal :trace, appender.level
      end
    end

    describe "#console_output?" do
      it "is false by default" do
        refute_predicate appender, :console_output?
      end
    end

    describe "#console_stream" do
      it "is nil by default" do
        assert_nil appender.console_stream
      end
    end

    describe "trace capture" do
      include SignalTrapHelper

      let(:trace_context) { SemanticLogger::Otlp::TraceContext }
      let(:capture) { SemanticLogger::Otlp::TraceContext::CAPTURE }

      # Without the appenders that other tests left open.
      before do
        @owners = trace_context.instance_variable_get(:@owners)
        trace_context.instance_variable_set(:@owners, {}.compare_by_identity)
        SemanticLogger::Logger.unsubscribe(capture)
      end

      after do
        trace_context.instance_variable_set(:@owners, @owners)
        @owners.empty? ? SemanticLogger::Logger.unsubscribe(capture) : SemanticLogger.on_log(capture)
      end

      it "captures the trace while its formatter writes it, until it is closed" do
        json = SemanticLogger::Appender::IO.new($stdout, formatter: :json)

        assert trace_context.registered?(json)
        assert_includes SemanticLogger::Logger.subscribers, capture
        json.close

        refute trace_context.registered?(json)
        refute_includes Array(SemanticLogger::Logger.subscribers), capture
      end

      it "does not capture it for a formatter that does not write it" do
        appender = SemanticLogger::Appender::IO.new($stdout, formatter: :default)

        refute trace_context.registered?(appender)
        refute_includes Array(SemanticLogger::Logger.subscribers), capture
      end

      it "stops capturing it once given a formatter that does not write it, and captures it again for one that does" do
        appender = SemanticLogger::Appender::IO.new($stdout, formatter: :json)
        appender.formatter = :default

        refute trace_context.registered?(appender)
        appender.formatter = :json

        assert trace_context.registered?(appender)
      ensure
        appender&.close
      end

      it "captures it again when written to after it was closed" do
        appender = SemanticLogger::Appender::IO.new(StringIO.new, formatter: :json)
        appender.close
        appender.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "again" })

        assert trace_context.registered?(appender)
      ensure
        appender&.close
      end

      it "is released by the close of each built-in appender, which calls super" do
        Dir.mktmpdir do |dir|
          appender = SemanticLogger::Appender::File.new(File.join(dir, "test.log"), formatter: :json)

          assert trace_context.registered?(appender)
          appender.close

          refute trace_context.registered?(appender)
        end
      end

      # Waits for a change asked for in a signal trap, which a new thread applies.
      def wait_for(deadline = Time.now + 5)
        sleep(0.01) until yield || Time.now > deadline
        yield
      end

      it "registers and releases it in a signal trap" do
        appender = in_signal_trap { SemanticLogger::Appender::IO.new(StringIO.new, formatter: :json) }

        refute_kind_of Exception, appender
        assert(wait_for { trace_context.registered?(appender) })
        closed = in_signal_trap { appender.close || :closed }

        assert_equal :closed, closed
        assert(wait_for { !trace_context.registered?(appender) })
      end

      it "applies the changes asked for in a signal trap before those asked for after it" do
        appender = SemanticLogger::Appender::IO.new(StringIO.new, formatter: :json)
        # Held, so that the change asked for in the trap waits on the queue.
        trace_context.instance_variable_get(:@mutex).synchronize do
          in_signal_trap { appender.close }
        end
        appender.formatter = :json

        assert trace_context.registered?(appender)
      ensure
        appender&.close
      end

      it "releases the appender that add_appender built for an io: when it fails afterwards" do
        assert_raises(ArgumentError) { SemanticLogger.add_appender(io: StringIO.new, formatter: :json, batch: true) }
        assert_empty trace_context.instance_variable_get(:@owners)
      end

      it "releases a second console appender, which add_appender drops" do
        first = SemanticLogger.add_appender(io: $stdout, formatter: :default)
        SemanticLogger.add_appender(io: $stdout, formatter: :json)

        assert_empty trace_context.instance_variable_get(:@owners)
      ensure
        SemanticLogger.remove_appender(first) if first
      end

      it "releases it when the appender cannot be built" do
        failing = Class.new(SemanticLogger::Appender::IO) do
          def initialize(*, **)
            super
            raise IOError, "cannot open"
          end
        end

        assert_raises(IOError) { failing.new(StringIO.new, formatter: :json) }
        assert_empty trace_context.instance_variable_get(:@owners)
        refute_includes Array(SemanticLogger::Logger.subscribers), capture
      end
    end

    describe "#batch_all_or_nothing?" do
      it "is false by default, since #batch may have written some messages before raising" do
        refute_predicate appender, :batch_all_or_nothing?
      end
    end

    describe "#batch_refusal" do
      it "is nil whatever the formatter, since #batch may format each log message with #format_log" do
        appender.formatter = ->(log, _logger) { log.message }

        assert_nil appender.batch_refusal
      end
    end

    describe "#format_batch_refusal" do
      it "is nil for a formatter that implements #batch" do
        appender.formatter = :json

        assert_nil appender.send(:format_batch_refusal)
      end

      it "names the class of a formatter that cannot format a batch, and says what to do instead" do
        appender.formatter = ->(log, _logger) { log.message }

        assert_equal "its formatter, Proc, cannot format a batch. Give it a formatter that implements " \
                     "#batch(logs, logger), or add it with batch: false.",
                     appender.send(:format_batch_refusal)

        appender.formatter = :color

        assert_match(/\Aits formatter, SemanticLogger::Formatters::Color, cannot format a batch\. /,
                     appender.send(:format_batch_refusal))
      end

      it "says only to add it with batch: false when the appender is its own formatter" do
        own = Class.new(SemanticLogger::Subscriber) do
          def call(log, _logger) = log.message

          def batch(logs) = logs
        end.new

        assert_equal "it is its own formatter, which cannot format a batch. Add it with batch: false.",
                     own.send(:format_batch_refusal)
      end
    end

    describe "#inspect" do
      it "shows the class and object address, but not the instance variables" do
        appender.instance_variable_set(:@password, "s3cr3t")

        assert_match(/\A#<SubscriberTest::SimpleSubscriber:0x\h+>\z/, appender.inspect)
      end

      it "adds the details that the appender says are safe to show" do
        appender.define_singleton_method(:inspect_details) { %(queue_name="logs") }

        assert_match(/\A#<SubscriberTest::SimpleSubscriber:0x\h+ queue_name="logs">\z/, appender.inspect)
      end
    end

    describe "#format_log and #format_batch" do
      let(:log) { SemanticLogger::Log.new("SubscriberTest", :info).tap { |l| l.message = "hello" } }

      def formatter_raising(exception)
        formatter = Object.new
        formatter.define_singleton_method(:call) { |_log, _logger| raise exception }
        formatter.define_singleton_method(:batch) { |_logs, _logger| raise exception }
        formatter
      end

      it "returns the formatted log message" do
        assert_match(/ I .* SubscriberTest -- hello\z/, appender.send(:format_log, log))
      end

      it "raises any error from the formatter as a FormatError, with the error as its cause" do
        [NoMethodError.new("undefined method 'each' for an instance of String"),
         ArgumentError.new("invalid byte sequence in UTF-8"),
         NotImplementedError.new("ExceptionFixtures::AbstractMessageError must define #message"),
         LoadError.new("cannot load such file -- amazing_print")].each do |error|
          appender.instance_variable_set(:@formatter, formatter_raising(error))

          [-> { appender.send(:format_log, log) }, -> { appender.send(:format_batch, [log]) }].each do |format|
            raised = assert_raises(SemanticLogger::Subscriber::FormatError, &format)

            assert_same error, raised.cause
            assert appender.message_error?(raised), "expected a FormatError to be a message error"
          end
        end
      end

      it "names the formatter's error by its class as Ruby names it, even one that names itself otherwise, or raises" do
        {
          ExceptionFixtures::OtherwiseNamedError => "ExceptionFixtures::OtherwiseNamedError",
          ExceptionFixtures::UnnameableError     => "ExceptionFixtures::UnnameableError"
        }.each_pair do |error_class, name|
          appender.instance_variable_set(:@formatter, formatter_raising(error_class.new("declined")))
          one   = assert_raises(SemanticLogger::Subscriber::FormatError) { appender.send(:format_log, log) }
          batch = assert_raises(SemanticLogger::Subscriber::FormatError) { appender.send(:format_batch, [log]) }

          assert_equal "Could not format the log message (#{name})", one.message
          assert_equal "Could not format the batch of log messages (#{name})", batch.message
        end
      end

      it "raises a stack overflow as it is, so that rescuing StandardError cannot swallow it" do
        error = SystemStackError.new("stack level too deep")
        appender.instance_variable_set(:@formatter, formatter_raising(error))

        assert_same error, assert_raises(SystemStackError) { appender.send(:format_log, log) }
        assert_same error, assert_raises(SystemStackError) { appender.send(:format_batch, [log]) }
      end

      it "raises ArgumentError, not a FormatError, for a formatter that cannot format a batch" do
        appender.instance_variable_set(:@formatter, ->(log, _logger) { log.message })

        error = assert_raises(ArgumentError) { appender.send(:format_batch, [log]) }

        refute appender.message_error?(error)
        assert_equal "Cannot batch #{appender.class}: #{appender.send(:format_batch_refusal)}", error.message
      end

      it "raises ArgumentError for an appender that is its own formatter, whose #batch is its own" do
        own = Class.new(SemanticLogger::Subscriber) do
          def call(log, _logger) = log.message

          def batch(logs) = logs
        end.new

        assert_same own, own.formatter
        assert_raises(ArgumentError) { own.send(:format_batch, [log]) }
      end
    end

    describe "#message_error?" do
      it "is true for errors raised by formatting content that cannot be written" do
        [
          SemanticLogger::Subscriber::FormatError.new("Could not format the log message (NoMethodError)"),
          JSON::GeneratorError.new("cannot serialize"),
          JSON::NestingError.new("nesting of 101 is too deep"),
          Encoding::UndefinedConversionError.new("cannot convert"),
          FloatDomainError.new("NaN")
        ].each do |exception|
          assert appender.message_error?(exception), "expected #{exception.class} to be a message error"
        end
      end

      it "is false for a stack overflow, which the queue processor handles itself" do
        refute appender.message_error?(SystemStackError.new("stack level too deep"))
      end

      it "is false for a response from the destination that cannot be parsed" do
        refute appender.message_error?(JSON::ParserError.new("unexpected token at '<html>'"))
      end

      it "is false for other errors, such as the destination being unavailable" do
        refute appender.message_error?(Errno::ECONNREFUSED.new)
        refute appender.message_error?(RuntimeError.new("boom"))
      end
    end
  end
end
