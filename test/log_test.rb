require_relative "test_helper"

module SemanticLogger
  class LogTest < Minitest::Test
    describe SemanticLogger::Log do
      let(:log) do
        SemanticLogger::Log.new("LogTest", :info)
      end

      let(:exception) do
        raise "An exception"
      rescue RuntimeError => e
        e
      end

      describe "#initialize" do
        it "sets the supplied name and level" do
          assert_equal "LogTest", log.name
          assert_equal :info, log.level
        end

        it "derives the level_index from the level" do
          assert_equal SemanticLogger::Levels.index(:info), log.level_index
        end

        it "uses the supplied index when given" do
          log = SemanticLogger::Log.new("LogTest", :info, 99)

          assert_equal 99, log.level_index
        end

        it "captures the current thread name and time" do
          assert_equal Thread.current.name, log.thread_name
          assert_kind_of Time, log.time
        end
      end

      describe "#assign" do
        it "returns true for a normal log entry" do
          assert log.assign(message: "Hello")
          assert_equal "Hello", log.message
        end

        it "assigns the core fields" do
          log.assign(message: "Hello", payload: {a: 1}, duration: 5.0, metric: "m", metric_amount: 2)

          assert_equal "Hello", log.message
          assert_equal({a: 1}, log.payload)
          assert_in_delta(5.0, log.duration)
          assert_equal "m", log.metric
          assert_equal 2, log.metric_amount
        end

        it "suppresses the entry when duration is below min_duration" do
          refute log.assign(message: "Hello", duration: 1.0, min_duration: 100.0)
        end

        it "still logs a short duration when an exception is present" do
          assert log.assign(message: "Hello", duration: 1.0, min_duration: 100.0, exception: exception)
        end

        describe "exception handling" do
          it "assigns the exception when log_exception is :full" do
            log.assign(exception: exception, log_exception: :full)

            assert_equal exception, log.exception
          end

          it "folds the exception into the message when log_exception is :partial" do
            log.assign(message: "Boom", exception: exception, log_exception: :partial)

            assert_nil log.exception
            assert_equal "Boom -- Exception: RuntimeError: An exception", log.message
          end

          it "ignores the exception when log_exception is :none" do
            log.assign(message: "Boom", exception: exception, log_exception: :none)

            assert_nil log.exception
            assert_equal "Boom", log.message
          end

          it "raises for an invalid log_exception value" do
            assert_raises ArgumentError do
              log.assign(exception: exception, log_exception: :bogus)
            end
          end

          it "accepts the same log_exception values that log_exception_option? accepts" do
            [:full, :partial, :none, nil].each do |value|
              assert SemanticLogger::Log.log_exception_option?(value), "value: #{value.inspect}"
              log.assign(exception: exception, log_exception: value)
            end
            [:bogus, "full", 1].each do |value|
              refute SemanticLogger::Log.log_exception_option?(value), "value: #{value.inspect}"
              assert_raises(ArgumentError) { log.assign(exception: exception, log_exception: value) }
            end
          end

          it "coerces a non-exception into an ArgumentError" do
            log.assign(exception: "not an exception")

            assert_kind_of ArgumentError, log.exception
            assert_match(/Invalid value for logger exception/, log.exception.message)
          end

          it "coerces a non-exception too deep for #inspect without raising, on a thread" do
            nested = "leaf"
            5_000.times { nested = {a: nested} }

            Thread.new { log.assign(exception: nested) }.join

            assert_kind_of ArgumentError, log.exception
            assert_includes log.exception.message, "#<Hash nested too deeply>"
          end

          it "changes the level when on_exception_level is supplied" do
            log.assign(exception: exception, on_exception_level: :fatal)

            assert_equal :fatal, log.level
            assert_equal SemanticLogger::Levels.index(:fatal), log.level_index
          end

          it "stores an on_exception_level supplied as a String or Integer as its Symbol" do
            log.assign(exception: exception, on_exception_level: ::Logger::ERROR)

            assert_equal :error, log.level

            log.assign(exception: exception, on_exception_level: "Fatal")

            assert_equal :fatal, log.level
          end
        end

        describe "backtrace" do
          it "extracts a supplied backtrace" do
            log.assign(message: "Hello", backtrace: ["/app/foo.rb:1", "/app/bar.rb:2"])

            assert_equal ["/app/foo.rb:1", "/app/bar.rb:2"], log.backtrace
          end

          it "captures a backtrace when the level meets backtrace_level" do
            with_backtrace_level(:trace) do
              log = SemanticLogger::Log.new("LogTest", :info)
              log.assign(message: "Hello")

              refute_nil log.backtrace
            end
          end

          it "does not capture a backtrace when below backtrace_level" do
            with_backtrace_level(:fatal) do
              log = SemanticLogger::Log.new("LogTest", :info)
              log.assign(message: "Hello")

              assert_nil log.backtrace
            end
          end
        end
      end

      describe "#assign_hash" do
        it "assigns known keys to self and unknown keys to the payload" do
          log.assign_hash(message: "Hello", user: "joe")

          assert_equal "Hello", log.message
          assert_equal({user: "joe"}, log.payload)
        end

        it "leaves the payload nil when only known keys are supplied" do
          log.assign_hash(message: "Hello")

          assert_nil log.payload
        end

        it "returns self" do
          assert_equal log, log.assign_hash(message: "Hello")
        end

        it "does not overwrite first-class attributes from the supplied hash" do
          log.assign_hash(level: :fatal, name: "Spoofed", time: "now", user: "joe")

          # The protected fields are unchanged and routed to the payload instead.
          refute_equal :fatal, log.level
          refute_equal "Spoofed", log.name
          assert_equal({level: :fatal, name: "Spoofed", time: "now", user: "joe"}, log.payload)
        end

        it "still assigns non-payload keys such as duration" do
          log.assign_hash(message: "Hello", duration: 123)

          assert_equal "Hello", log.message
          assert_equal 123, log.duration
          assert_nil log.payload
        end
      end

      describe "#extract_arguments" do
        it "raises when the payload is not a Hash" do
          assert_raises ArgumentError do
            log.extract_arguments("not a hash")
          end
        end

        it "splits non-payload keys out of the payload" do
          args = log.extract_arguments(user: "joe", duration: 5)

          assert_equal({payload: {user: "joe"}, duration: 5}, args)
        end

        it "returns the hash unchanged when it already has a :payload key" do
          args = log.extract_arguments(payload: {a: 1}, message: "hi")

          assert_equal({payload: {a: 1}, message: "hi"}, args)
        end

        it "merges a supplied message when a :payload key is present" do
          args = log.extract_arguments({payload: {a: 1}}, "hello")

          assert_equal({payload: {a: 1}, message: "hello"}, args)
        end

        it "treats an empty message as no message" do
          args = log.extract_arguments({user: "joe"}, "")

          assert_equal({payload: {user: "joe"}}, args)
        end

        describe "untrusted hashes" do
          # Like ActiveSupport::HashWithIndifferentAccess, which is what params.to_unsafe_h returns.
          let(:indifferent_hash_class) do
            Class.new(Hash) do
              def key?(key) = super(key.to_s)
            end
          end

          it "keeps a \"payload\" key of an indifferent access hash in the payload" do
            params = indifferent_hash_class.new.merge!("user" => "bob", "payload" => "x")
            args   = log.extract_arguments(params, "Params")

            assert_equal({payload: {"user" => "bob", "payload" => "x"}, message: "Params"}, args)
            assert log.assign(**args)
          end

          it "merges unknown keys into an explicit payload instead of passing them on" do
            args = log.extract_arguments({payload: {a: 1}, user: "bob", duration: 5})

            assert_equal({payload: {a: 1, user: "bob"}, duration: 5}, args)
            assert log.assign(**args)
          end

          it "lets the explicit payload win over a stray key with the same name" do
            args = log.extract_arguments({payload: {user: "real"}, user: "spoof"}, "msg")

            assert_equal({payload: {user: "real"}, message: "msg"}, args)
          end

          it "ignores a log argument with a nil value, so that its default is used" do
            args = log.extract_arguments({duration: 1, min_duration: nil, log_exception: nil, user: "bob"}, "m")

            assert_equal({duration: 1, payload: {user: "bob"}, message: "m"}, args)
            assert log.assign(**args), "a nil min_duration must not make the logging call raise"
          end

          it "keeps an explicit payload that is not a hash alongside unknown keys" do
            args = log.extract_arguments({payload: "text", user: "bob"})

            assert_equal({payload: {user: "bob", payload: "text"}}, args)
          end

          it "keeps values that cannot be used as log arguments in the payload" do
            untrusted = {
              log_exception:      "boom",
              on_exception_level: "nope",
              duration:           "0",
              min_duration:       [],
              backtrace:          "not an array",
              metric_amount:      Float::INFINITY,
              dimensions:         "x"
            }
            args = log.extract_arguments({exception: 1}.merge(untrusted), "Webhook")

            assert_equal untrusted, args[:payload]
            assert log.assign(**args), "an untrusted hash must not make the logging call raise"
          end

          it "keeps other values that #assign or the formatters cannot use in the payload" do
            untrusted = {
              backtrace:          [1, 2],
              on_exception_level: 2**70,
              duration:           Complex(1, 1),
              min_duration:       Float::NAN
            }
            args = log.extract_arguments({exception: "x"}.merge(untrusted), "Webhook")

            assert_equal untrusted, args[:payload]
            assert log.assign(**args), "an untrusted hash must not make the logging call raise"
          end

          it "does not modify a backtrace supplied in the hash" do
            backtrace = ["/gems/foo/lib/semantic_logger/logger.rb:10", "/app/models/user.rb:30"]
            log.assign(**log.extract_arguments({backtrace: backtrace}, "m"))

            assert_equal ["/app/models/user.rb:30"], log.backtrace
            assert_equal 2, backtrace.size
          end

          it "uses values of the right type as log arguments" do
            args = log.extract_arguments(
              {log_exception: :partial, on_exception_level: "error", duration: 1.5, metric_amount: 3}, "m"
            )

            assert_equal({log_exception: :partial, on_exception_level: "error", duration: 1.5, metric_amount: 3,
                          message: "m"}, args)
          end
        end

        it "lets a supplied message take precedence over a payload message key" do
          args = log.extract_arguments({message: "inner"}, "outer")

          assert_equal({payload: {message: "inner"}, message: "outer"}, args)
        end
      end

      describe "#each_exception" do
        it "yields the exception and any nested causes with their depth" do
          ex =
            begin
              begin
                raise "the cause"
              rescue StandardError
                raise "the effect"
              end
            rescue StandardError => e
              e
            end
          log.exception = ex

          collected = []
          log.each_exception { |e, depth| collected << [e.message, depth] }

          assert_equal [["the effect", 0], ["the cause", 1]], collected
        end

        it "does not yield when there is no exception" do
          yielded = false
          log.each_exception { yielded = true }

          refute yielded
        end
      end

      describe "#backtrace_to_s" do
        it "joins the exception backtrace" do
          exception.set_backtrace(%w[line1 line2])
          log.exception = exception

          assert_equal "line1\nline2", log.backtrace_to_s
        end

        it "returns an empty string without an exception" do
          assert_equal "", log.backtrace_to_s
        end

        describe "with causes" do
          # An exception whose cause can be assigned directly, to build any chain,
          # including a cyclic one that `raise` would refuse.
          let(:chained_error) { Class.new(StandardError) { attr_accessor :cause } }

          def chained(message, backtrace, cause = nil)
            error = chained_error.new(message)
            error.set_backtrace(backtrace) if backtrace
            error.cause = cause
            error
          end

          it "lays out every exception in a three deep chain" do
            root          = chained("root\ncause", %w[r1 r2])
            middle        = chained("middle", %w[m1], root)
            log.exception = chained("top", %w[t1 t2], middle)
            name          = chained_error.name

            expected = "t1\nt2\nCause: #{name}: middle\nm1\nCause: #{name}: root\ncause\nr1\nr2"

            assert_equal expected, log.backtrace_to_s
          end

          it "lays out a cause without a backtrace" do
            log.exception = chained("top", %w[t1], chained("cause", nil))

            assert_equal "t1\nCause: #{chained_error.name}: cause\n", log.backtrace_to_s
          end

          it "stops at a cyclic cause chain" do
            first         = chained("first", %w[f1])
            second        = chained("second", %w[s1], first)
            first.cause   = second
            log.exception = first

            assert_equal "f1\nCause: #{chained_error.name}: second\ns1", log.backtrace_to_s
          end

          it "passes each cause message and backtrace line to the block" do
            log.exception = chained("top\nmsg", %w[t1], chained("cause\nmsg", %w[c1]))
            name          = chained_error.name

            trace         = log.backtrace_to_s { |text| "<#{text}>" }

            assert_equal "<t1>\nCause: #{name}: <cause\nmsg>\n<c1>", trace
          end
        end
      end

      describe "#exception_details" do
        # Supplies its own detail, the same way on every Ruby version.
        detailed_error = Class.new(StandardError) do
          def detailed_message(highlight: false, **)
            "#{super}\n  order_id: 42"
          end
        end

        let(:raised) do
          lambda do |&block|
            block.call
          rescue Exception => e
            e
          end
        end

        it "returns the detail an exception class adds, without the message or class name" do
          ex = raised.call { raise detailed_error, "Order rejected" }

          assert_equal "  order_id: 42", log.exception_details(ex)
        end

        it "returns did_you_mean suggestions" do
          user_name = "jack"
          ex        = raised.call { user_name.upcas }

          assert_match(/\ADid you mean\?  upcase/, log.exception_details(ex))
        end

        it "omits the source snippet by default" do
          user_name = "jack"
          ex        = raised.call { user_name.upcas }

          refute_includes log.exception_details(ex), "user_name.upcas"
        end

        it "includes the source snippet when requested" do
          user_name = "jack"
          ex        = raised.call { user_name.upcas }

          assert_includes log.exception_details(ex, source: true), "user_name.upcas"
        end

        it "returns nil when there is no detail" do
          assert_nil log.exception_details(exception)
        end

        it "returns nil for a multi-line message" do
          ex = raised.call { raise "line one\nline two" }

          assert_nil log.exception_details(ex)
        end

        it "supports an override that does not accept extra keyword arguments" do
          strict_error = Class.new(StandardError) do
            def detailed_message(highlight: false)
              "#{super}\n  strict detail"
            end
          end
          ex = raised.call { raise strict_error, "strict" }

          assert_equal "  strict detail", log.exception_details(ex)
        end

        it "omits the source snippet when an error_highlight override does not accept extra keyword arguments" do
          ex = raised.call { raise NameError.new("strict", :user_name) }
          # Stands in for error_highlight's snippet, which it only adds to an exception raised by a failing call.
          ex.define_singleton_method(:detailed_message) do |highlight: false|
            "#{super(highlight: highlight)}\n  user_name.upcas\n           ^^^^^^"
          end

          assert_nil log.exception_details(ex)
          assert_includes log.exception_details(ex, source: true), "user_name.upcas"
        end

        it "returns nil when an override raises" do
          raising_error = Class.new(StandardError) do
            def detailed_message(**)
              raise "broken override"
            end
          end
          ex = raised.call { raise raising_error, "raising" }

          assert_nil log.exception_details(ex)
        end

        it "returns nil when an override replaces the message" do
          rewriting_error = Class.new(StandardError) do
            def detailed_message(**)
              "something else entirely"
            end
          end
          ex = raised.call { raise rewriting_error, "rewrite" }

          assert_nil log.exception_details(ex)
        end

        it "calls #detailed_message once per exception and option" do
          ex    = raised.call { raise detailed_error, "Order rejected" }
          calls = 0
          ex.define_singleton_method(:detailed_message) do |**opts|
            calls += 1
            super(**opts)
          end

          3.times { log.exception_details(ex) }
          log.exception_details(ex, source: true)

          assert_equal 2, calls
        end
      end

      describe "#duration_human and #duration_to_s" do
        it "returns nil without a duration" do
          assert_nil log.duration_human
          assert_nil log.duration_to_s
        end

        it "formats sub-second durations" do
          log.duration = 1.34567
          expected = SemanticLogger::Formatters::Base::PRECISION == 3 ? "1ms" : "1.346ms"

          assert_equal expected, log.duration_to_s
          assert_equal expected, log.duration_human
        end

        it "formats seconds" do
          log.duration = 1_000.0

          assert_equal "1.000s", log.duration_human
        end

        it "formats minutes" do
          log.duration = 60_000.0

          assert_equal "1m 0s", log.duration_human
        end

        it "formats hours" do
          log.duration = 3_600_000.0

          assert_equal "1h 0m", log.duration_human
        end

        it "formats days" do
          log.duration = 86_400_000.0

          assert_equal "1d 0h 0m", log.duration_human
        end
      end

      describe "#level_to_s" do
        it "returns the upper case first character of the level" do
          assert_equal "I", SemanticLogger::Log.new("n", :info).level_to_s
          assert_equal "D", SemanticLogger::Log.new("n", :debug).level_to_s
          assert_equal "W", SemanticLogger::Log.new("n", :warn).level_to_s
        end
      end

      describe "#extract_file_and_line / #file_name_and_line" do
        let(:stack) do
          ["/path/to/file.rb:42:in `some_method'", "/path/to/other.rb:7"]
        end

        it "extracts the file and line from a stack" do
          assert_equal ["/path/to/file.rb", 42], log.extract_file_and_line(stack)
        end

        it "returns the basename when short_name is true" do
          assert_equal ["file.rb", 42], log.extract_file_and_line(stack, true)
        end

        it "returns nil for an empty or nil stack" do
          assert_nil log.extract_file_and_line(nil)
          assert_nil log.extract_file_and_line([])
        end

        it "uses the log backtrace" do
          log.backtrace = stack

          assert_equal ["/path/to/file.rb", 42], log.file_name_and_line
        end

        it "falls back to the exception backtrace" do
          exception.set_backtrace(stack)
          log.exception = exception

          assert_equal ["/path/to/file.rb", 42], log.file_name_and_line
        end
      end

      describe "#cleansed_message" do
        {
          "\e[32m[SUCCESS] User profile updated successfully!\e[0m" => "[SUCCESS] User profile updated successfully!",
          "[SUCCESS] User profile updated successfully!"            => "[SUCCESS] User profile updated successfully!",
          "  \e[31mError\e[0m  "                                    => "Error",
          "\e[31;1mBold red\e[0m and \e[34mblue\e[0m"               => "Bold red and blue",
          "\etest string \n"                                        => "test string",
          " test strip string \n"                                   => "test strip string",
          "no escapes here"                                         => "no escapes here"
        }.each_pair do |message, expected|
          it "cleanses #{message.inspect}" do
            log.message = message

            assert_equal expected, log.cleansed_message
          end
        end

        {
          "Search: \e\xFF" => "Search:",
          "\xFFabc"        => "abc",
          "Search: \xFF"   => "Search:"
        }.each_pair do |message, expected|
          it "drops the invalid bytes of #{message.inspect} tagged UTF-8, instead of raising" do
            log.message = (+message).force_encoding(Encoding::UTF_8)

            assert_equal expected, log.cleansed_message
          end
        end
      end

      describe "#payload? and #payload_to_s" do
        it "is false for a nil payload" do
          refute_predicate log, :payload?
          assert_nil log.payload_to_s
        end

        it "is false for an empty payload" do
          log.payload = {}

          refute_predicate log, :payload?
          assert_nil log.payload_to_s
        end

        it "is true for a populated payload" do
          log.payload = {a: 1}

          assert_predicate log, :payload?
          assert_equal log.payload.inspect, log.payload_to_s
        end

        it "renders a payload too deep for #inspect without raising, on a thread" do
          nested = "leaf"
          5_000.times { nested = {a: nested} }
          log.payload = {body: nested}

          text = Thread.new { log.payload_to_s }.value

          assert_includes text, "#<Hash nested too deeply>"
        end
      end

      describe "#to_h" do
        it "returns a raw hash including the supplied host, application, and environment" do
          log.message = "Hello"
          hash = log.to_h("my_host", "my_app", "my_env")

          assert_equal "my_host", hash[:host]
          assert_equal "my_app",  hash[:application]
          assert_equal "my_env",  hash[:environment]
          assert_equal "LogTest", hash[:name]
          assert_equal "Hello",   hash[:message]
        end
      end

      describe "#set_context" do
        it "lazily initializes and assigns context" do
          log.set_context(:request_id, "abc")

          assert_equal({request_id: "abc"}, log.context)
        end

        it "merges additional context entries" do
          log.set_context(:request_id, "abc")
          log.set_context(:user, "joe")

          assert_equal({request_id: "abc", user: "joe"}, log.context)
        end
      end

      describe "#metric_only?" do
        it "is true when only a metric is present" do
          log.metric = "user/login"

          assert_predicate log, :metric_only?
        end

        it "is false when a message is present" do
          log.metric  = "user/login"
          log.message = "Hello"

          refute_predicate log, :metric_only?
        end

        it "is false without a metric" do
          refute_predicate log, :metric_only?
        end
      end

      def with_backtrace_level(level)
        original = SemanticLogger.backtrace_level
        SemanticLogger.backtrace_level = level
        yield
      ensure
        SemanticLogger.backtrace_level = original
      end
    end
  end
end
