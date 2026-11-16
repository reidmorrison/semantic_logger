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

        it "captures the time" do
          assert_kind_of Time, log.time
        end

        it "captures the current thread's name" do
          thread_name = Thread.new do
            Thread.current.name = "Worker 001"
            SemanticLogger::Log.new("LogTest", :info).thread_name
          end.value

          assert_equal "Worker 001", thread_name
        end

        it "captures the current thread's object id when the thread has no name" do
          thread_name, object_id = Thread.new do
            [SemanticLogger::Log.new("LogTest", :info).thread_name, Thread.current.object_id]
          end.value

          assert_equal object_id.to_s, thread_name
        end
      end

      describe ".thread_name_for" do
        it "returns the thread's name" do
          thread      = Thread.new { sleep }
          thread.name = "Worker 001"

          assert_equal "Worker 001", SemanticLogger::Log.thread_name_for(thread)
        ensure
          thread&.kill
        end

        it "returns the thread's object id when the thread has no name" do
          thread = Thread.new { sleep }

          assert_equal thread.object_id.to_s, SemanticLogger::Log.thread_name_for(thread)
        ensure
          thread&.kill
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

          describe "with causes when log_exception is :partial" do
            # Returns the exception raised with the supplied message while rescuing the supplied cause.
            def raise_with_cause(cause, message = "save failed")
              begin
                raise cause
              rescue StandardError
                raise message
              end
            rescue StandardError => e
              e
            end

            it "folds each cause's class and message into the message" do
              exception = raise_with_cause(IOError.new("disk full"))
              log.assign(message: "Boom", exception: exception, log_exception: :partial)

              assert_nil log.exception
              assert_equal "Boom -- Exception: RuntimeError: save failed -- Cause: IOError: disk full", log.message
            end

            it "folds the causes in order" do
              inner = raise_with_cause(IOError.new("disk full"), "write failed")
              log.assign(message: "Boom", exception: raise_with_cause(inner), log_exception: :partial)

              assert_equal "Boom -- Exception: RuntimeError: save failed -- Cause: RuntimeError: write failed " \
                           "-- Cause: IOError: disk full", log.message
            end

            it "leaves out a cause's message that the message already holds" do
              exception = raise_with_cause(IOError.new("disk full"), "Could not save: disk full")
              log.assign(message: "Boom", exception: exception, log_exception: :partial)

              assert_equal "Boom -- Exception: RuntimeError: Could not save: disk full -- Cause: IOError", log.message
            end

            it "leaves out a cause's message that a cause before it already holds" do
              inner = raise_with_cause(IOError.new("disk full"), "disk full")
              log.assign(message: "Boom", exception: raise_with_cause(inner), log_exception: :partial)

              assert_equal "Boom -- Exception: RuntimeError: save failed -- Cause: RuntimeError: disk full " \
                           "-- Cause: IOError", log.message
            end

            it "leaves out a cause's message that is empty" do
              log.assign(message: "Boom", exception: raise_with_cause(IOError.new("")), log_exception: :partial)

              assert_equal "Boom -- Exception: RuntimeError: save failed -- Cause: IOError", log.message
            end

            it "leaves out a cause's message that is its class name" do
              log.assign(message: "Boom", exception: raise_with_cause(IOError), log_exception: :partial)

              assert_equal "Boom -- Exception: RuntimeError: save failed -- Cause: IOError", log.message
            end

            it "folds in the same causes as the backtrace of :full" do
              exception = (0..Log::MAX_EXCEPTIONS_TO_UNWRAP).reduce(IOError.new("cause 0")) do |cause, i|
                raise_with_cause(cause, "cause #{i + 1}")
              end
              log.assign(message: "Boom", exception: exception, log_exception: :partial)
              full = SemanticLogger::Log.new("LogTest", :info).tap { |entry| entry.exception = exception }

              assert_equal full.backtrace_to_s.scan(/^Cause: .*$/).map { |line| " -- #{line}" }.join,
                           log.message.delete_prefix("Boom -- Exception: RuntimeError: cause 6")
            end

            it "folds in each cause once when the causes form a loop" do
              first  = RuntimeError.new("first")
              second = IOError.new("second")
              first.define_singleton_method(:cause) { second }
              second.define_singleton_method(:cause) { first }
              log.assign(message: "Boom", exception: first, log_exception: :partial)

              assert_equal "Boom -- Exception: RuntimeError: first -- Cause: IOError: second", log.message
            end

            it "folds a cause's message in another encoding into a UTF-8 message" do
              exception = raise_with_cause(IOError.new("Datei \xFC voll".b), "Speichern fehlgeschlagen ü")
              log.assign(message: "Grüße", exception: exception, log_exception: :partial)

              assert_equal "Grüße -- Exception: RuntimeError: Speichern fehlgeschlagen ü " \
                           "-- Cause: IOError: Datei  voll", log.message
            end
          end

          it "folds an exception message in another encoding into a UTF-8 message when log_exception is :partial" do
            binary = RuntimeError.new("Datei \xFC kaputt".b)
            log.assign(message: "Grüße", exception: binary, log_exception: :partial)

            assert_equal "Grüße -- Exception: RuntimeError: Datei  kaputt", log.message
            assert_predicate log.message, :valid_encoding?
          end

          it "folds an exception message into a message in another encoding when log_exception is :partial" do
            log.assign(message: "Gr\xFC\xDFe".b, exception: RuntimeError.new("Fehler ü"), log_exception: :partial)

            assert_equal "Gre -- Exception: RuntimeError: Fehler ü", log.message
            assert_equal Encoding::UTF_8, log.message.encoding
          end

          it "keeps a message in a convertible encoding when log_exception is :partial" do
            latin1 = "Gr\xFC\xDFe".dup.force_encoding(Encoding::ISO_8859_1)
            log.assign(message: latin1, exception: RuntimeError.new("Fehler ü"), log_exception: :partial)

            assert_equal "Grüße -- Exception: RuntimeError: Fehler ü", log.message
          end

          it "leaves a message in another encoding as it is when it can be joined when log_exception is :partial" do
            latin1 = "Gr\xFC\xDFe".dup.force_encoding(Encoding::ISO_8859_1)
            log.assign(message: latin1, exception: RuntimeError.new("Fehler"), log_exception: :partial)

            assert_equal Encoding::ISO_8859_1, log.message.encoding
            assert_equal "Grüße -- Exception: RuntimeError: Fehler", log.message.encode(Encoding::UTF_8)
            # Can still be joined with the application's other text in that encoding, such as a tag.
            assert_equal "Grüße -- Exception: RuntimeError: Fehler Grüße", "#{log.message} #{latin1}".encode("UTF-8")
          end

          it "folds a binary exception message into an ASCII message as UTF-8 when log_exception is :partial" do
            log.assign(message: "Boom", exception: RuntimeError.new("Datei \xFC kaputt".b), log_exception: :partial)

            assert_equal "Boom -- Exception: RuntimeError: Datei  kaputt", log.message
            assert_equal Encoding::UTF_8, log.message.encoding
          end

          it "folds the exception into an html_safe message as plain text when log_exception is :partial" do
            # Like ActiveSupport::SafeBuffer: #to_s returns itself and #+ escapes the text added to it.
            safe_buffer = Class.new(String) do
              def to_s = self
              def +(other) = self.class.new(super(other.to_s.gsub("'", "&#39;")))
            end
            log.assign(message: safe_buffer.new("Loaded"), exception: NoMethodError.new("undefined method 'title'"),
                       log_exception: :partial)

            assert_equal "Loaded -- Exception: NoMethodError: undefined method 'title'", log.message
            assert_instance_of String, log.message
          end

          it "folds an exception class name in another encoding into a UTF-8 message when log_exception is :partial" do
            klass = Class.new(StandardError)
            klass.define_singleton_method(:to_s) { "Fehl\xC4r".dup.force_encoding(Encoding::ISO_8859_1) }
            log.assign(message: "Grüße", exception: klass.new("kaputt"), log_exception: :partial)

            assert_equal "Grüße -- Exception: FehlÄr: kaputt", log.message
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

          it "accepts only :full, :partial, :none, or nil for log_exception" do
            [:full, :partial, :none, nil].each do |value|
              log.assign(exception: exception, log_exception: value)
            end

            [:bogus, "full", 1].each do |value|
              assert_raises(ArgumentError, value.inspect) { log.assign(exception: exception, log_exception: value) }
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

        it "keeps a value that is not valid for its argument in the payload, instead of assigning it" do
          untrusted = {exception: "boom", duration: "slow", backtrace: "x.rb:1", metric_amount: "1", dimensions: [1]}
          log.assign_hash(untrusted)

          assert_nil log.exception
          assert_nil log.duration
          assert_nil log.backtrace
          assert_nil log.metric_amount
          assert_nil log.dimensions
          assert_equal untrusted, log.payload
        end

        it "keeps a payload that is not a Hash in the payload, instead of replacing it" do
          log.assign_hash(payload: "x", user: "bob")

          assert_equal({payload: "x", user: "bob"}, log.payload)
        end

        it "merges a Hash payload, and ignores a nil one" do
          log.payload = {a: 1}
          log.assign_hash(payload: {b: 2})
          log.assign_hash(payload: nil)

          assert_equal({a: 1, b: 2}, log.payload)
        end

        it "uses the message only when the log call supplied none, keeping it in the payload otherwise" do
          log.message = "User 42 logged in"
          log.assign_hash(message: "User 7 deleted all invoices")

          assert_equal "User 42 logged in", log.message
          assert_equal({message: "User 7 deleted all invoices"}, log.payload)
        end

        it "keeps the values the log call supplied, adding the other keys" do
          log.payload = {user_id: 42}
          log.assign_hash(user_id: 1, admin: true, payload: {user_id: 2})

          assert_equal({user_id: 42, admin: true}, log.payload)
        end

        it "does not modify the caller's payload" do
          attributes  = {name: "bob"}
          log.payload = attributes
          log.assign_hash(admin: true)

          assert_equal({name: "bob"}, attributes)
          assert_equal({name: "bob", admin: true}, log.payload)
        end

        it "leaves a payload that is not a Hash unchanged when there is nothing to add" do
          log.payload = "text"
          log.assign_hash({})

          assert_equal "text", log.payload
        end

        it "lets the block's own key win over its payload's value, whatever their order" do
          log.assign_hash(payload: {account_id: 666}, account_id: 42)

          assert_equal({account_id: 42}, log.payload)

          other = SemanticLogger::Log.new("LogTest", :info)
          other.assign_hash(account_id: 42, payload: {account_id: 666})

          assert_equal({account_id: 42}, other.payload)
        end

        it "assigns the arguments the log call did not supply" do
          log.assign_hash(message: "Completed", duration: 1.5, metric: "rails.x", metric_amount: 2,
                          dimensions: {a: 1}, backtrace: ["app.rb:1"], exception: exception)

          assert_equal "Completed", log.message
          assert_in_delta(1.5, log.duration)
          assert_equal "rails.x", log.metric
          assert_equal 2, log.metric_amount
          assert_equal({a: 1}, log.dimensions)
          assert_equal ["app.rb:1"], log.backtrace
          assert_equal exception, log.exception
          assert_nil log.payload
        end

        it "keeps the arguments the log call supplied, adding the block's values to the payload" do
          supplied = RuntimeError.new("supplied")
          log.assign(message: "Webhook", duration: 5, metric: "app", metric_amount: 1, dimensions: {a: 1},
                     backtrace: ["app.rb:1"], exception: supplied)
          untrusted = {message: "forged", duration: 999, metric: "forged", metric_amount: 9, dimensions: {b: 2},
                       backtrace: ["forged.rb:1"], exception: exception}
          backtrace = log.backtrace
          log.assign_hash(untrusted)

          assert_equal "Webhook", log.message
          assert_equal 5, log.duration
          assert_equal "app", log.metric
          assert_equal 1, log.metric_amount
          assert_equal({a: 1}, log.dimensions)
          assert_equal supplied, log.exception
          assert_equal backtrace, log.backtrace
          assert_equal untrusted, log.payload
        end

        it "keeps the backtrace captured at the backtrace level" do
          with_backtrace_level(:error) do
            log = SemanticLogger::Log.new("LogTest", :error)
            log.assign(message: "Webhook")
            captured = log.backtrace
            log.assign_hash(backtrace: ["forged.rb:1"])

            refute_nil captured
            assert_equal captured, log.backtrace
            assert_equal({backtrace: ["forged.rb:1"]}, log.payload)
          end
        end

        it "lets the block's argument the log call supplied win over its payload's value" do
          log.duration = 5
          log.assign_hash(payload: {duration: 1}, duration: 2)

          assert_equal 5, log.duration
          assert_equal({duration: 2}, log.payload)
        end

        it "keeps the log call's value over a key of the same name, whether a String or a Symbol" do
          log.payload = {account_id: 42, "user" => "app"}
          log.assign_hash(JSON.parse('{"account_id":666,"event":"refund"}').merge(user: "untrusted"))

          assert_equal({account_id: 42, "user" => "app", "event" => "refund"}, log.payload)
        end

        it "uses the message when the log call's message is empty" do
          log.message = ""
          log.assign_hash(message: "From block")

          assert_equal "From block", log.message
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

          it "lets a key passed beside an explicit payload win over the payload's value of the same name" do
            # The explicit payload is where untrusted data goes, so it cannot replace the application's own value.
            args = log.extract_arguments({payload: {user: "untrusted"}, user: "app"}, "msg")

            assert_equal({payload: {user: "app"}, message: "msg"}, args)
          end

          it "lets a key passed beside an explicit payload win over the payload's String key of the same name" do
            args = log.extract_arguments({payload: {"user" => "untrusted", "id" => 1}, user: "app"}, "msg")

            assert_equal({payload: {user: "app", "id" => 1}, message: "msg"}, args)
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

        it "starts from a supplied exception instead of the entry's own" do
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
          log.exception = RuntimeError.new("the entry's own")

          collected = []
          log.each_exception(ex) { |e, depth| collected << [e.message, depth] }

          assert_equal [["the effect", 0], ["the cause", 1]], collected
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

            assert_equal "t1\nCause: #{chained_error.name}: cause", log.backtrace_to_s
          end

          it "lays out a cause of an exception without a backtrace" do
            log.exception = chained("top", nil, chained("cause", %w[c1]))

            assert_equal "Cause: #{chained_error.name}: cause\nc1", log.backtrace_to_s
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

          it "cleans the backtrace of every exception with the cleaner" do
            log.exception = chained("top", %w[gem t1], chained("cause", %w[c1 gem]))
            cleaner       = ->(lines) { lines - ["gem"] }

            assert_equal "t1\nCause: #{chained_error.name}: cause\nc1", log.backtrace_to_s(cleaner: cleaner)
          end

          it "passes each cleaned line to the block" do
            log.exception = chained("top", %w[gem t1])

            assert_equal "<t1>", log.backtrace_to_s(cleaner: ->(lines) { lines - ["gem"] }) { |text| "<#{text}>" }
          end
        end
      end

      describe "#backtrace_of" do
        let(:cleaner) do
          Class.new do
            attr_reader :calls

            def clean(lines)
              @calls = (@calls || 0) + 1
              lines - ["gem"]
            end
          end.new
        end

        before do
          exception.set_backtrace(%w[gem app])
          log.exception = exception
        end

        it "returns the exception's own backtrace without a cleaner" do
          assert_same exception.backtrace, log.backtrace_of(exception)
        end

        it "returns nil for an exception without a backtrace" do
          assert_nil log.backtrace_of(RuntimeError.new("Not raised"), cleaner: cleaner)
        end

        it "cleans the backtrace given to an exception after it was asked for without one" do
          never_raised = RuntimeError.new("Not raised")

          assert_nil log.backtrace_of(never_raised, cleaner: cleaner)
          never_raised.set_backtrace(%w[gem app])

          assert_equal %w[app], log.backtrace_of(never_raised, cleaner: cleaner)
        end

        it "returns the full backtrace for a value that cannot clean one, such as the formatter option true" do
          internal  = InMemoryAppender.new
          processor = SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new(internal))
          SemanticLogger::Logger.stub(:processor, processor) do
            assert_equal %w[gem app], log.backtrace_of(exception, cleaner: true)
            assert_equal "gem\napp", log.backtrace_to_s(cleaner: true)
          end

          assert_match(/\ABacktrace cleaner raised NoMethodError/, internal.message.message)
        end

        it "keeps apart the backtraces of exceptions that are #eql?" do
          value_error = Class.new(StandardError) do
            def eql?(other) = other.instance_of?(self.class) && other.message == message
            def hash = [self.class, message].hash
          end
          first  = value_error.new("same").tap { |e| e.set_backtrace(%w[gem first]) }
          second = value_error.new("same").tap { |e| e.set_backtrace(%w[gem second]) }

          assert_equal %w[first], log.backtrace_of(first, cleaner: cleaner)
          assert_equal %w[second], log.backtrace_of(second, cleaner: cleaner)
        end

        it "keeps what was cached on the entry while the cleaner ran" do
          calls   = 0
          extract = lambda do |*, **|
            calls += 1
            "details"
          end
          SemanticLogger::ExceptionDetails.stub(:extract, extract) do
            log.backtrace_of(exception, cleaner: ->(lines) { lines.tap { log.exception_details(exception) } })
            log.exception_details(exception)
          end

          assert_equal 1, calls
        end

        it "returns the backtrace as the cleaner cleans it, leaving the exception's unchanged" do
          assert_equal %w[app], log.backtrace_of(exception, cleaner: cleaner)
          assert_equal %w[gem app], exception.backtrace
        end

        it "asks the cleaner once, for every formatter that asks" do
          2.times { log.backtrace_of(exception, cleaner: cleaner) }

          assert_equal 1, cleaner.calls
        end

        it "keeps the result of each cleaner apart" do
          log.backtrace_of(exception, cleaner: cleaner)

          assert_equal %w[gem], log.backtrace_of(exception, cleaner: ->(lines) { lines - ["app"] })
        end

        it "keeps cleaned backtraces apart from the cached exception details" do
          assert_nil log.exception_details(exception)
          assert_equal %w[app], log.backtrace_of(exception, cleaner: cleaner)
          assert_nil log.exception_details(exception)
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

        it "does not take the file name from a line after a forged line break" do
          assert_nil log.extract_file_and_line(["forged\n/path/to/file.rb:42"])
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

        it "uses the call site before the backtrace and the exception backtrace" do
          exception.set_backtrace(stack)
          log.exception = exception
          log.backtrace = stack
          log.call_site = SemanticLogger::CallSite.new(path: "/app/order.rb", line: 12, label: "Order#submit")

          assert_equal ["/app/order.rb", 12], log.file_name_and_line
          assert_equal ["order.rb", 12], log.file_name_and_line(true)
        end
      end

      describe "#cleansed_message in another encoding" do
        it "converts a message in another encoding to UTF-8 before stripping escape codes" do
          log.message = "hi \e[1m".encode(Encoding::UTF_16LE)

          assert_equal "hi", log.cleansed_message
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

      describe "#capture and #captured" do
        it "keeps the captured value apart from the context" do
          scope = Object.new
          log.capture(:scope, scope)

          assert_same scope, log.captured(:scope)
          assert_nil log.context
          assert_nil log.to_h[:captures]
        end

        it "returns nil when nothing was captured with the key" do
          assert_nil log.captured(:scope)
          log.capture(:other, 1)

          assert_nil log.captured(:scope)
        end
      end

      describe "#redact" do
        let(:redactor) { SemanticLogger::Redactor.new(%i[password authorization]) }
        let(:mask) { SemanticLogger::Redactor::MASK }

        it "redacts the payload, named tags, context, and metric dimensions" do
          log.payload    = {user: "jack", password: "x"}
          log.named_tags = {authorization: "Bearer abc", request_id: "r1"}.freeze
          log.set_context(:request, {headers: {"Authorization" => "Bearer abc"}})
          log.dimensions = {password: "x", region: "us"}
          log.redact(redactor)

          assert_equal({user: "jack", password: mask}, log.payload)
          assert_equal({authorization: mask, request_id: "r1"}, log.named_tags)
          assert_equal({request: {headers: {"Authorization" => mask}}}, log.context)
          assert_equal({password: mask, region: "us"}, log.dimensions)
        end

        it "leaves the replaced values, such as the application's payload and the shared named tags, unchanged" do
          payload        = {password: "x"}
          named_tags     = {authorization: "Bearer abc"}.freeze
          log.payload    = payload
          log.named_tags = named_tags
          log.redact(redactor)

          assert_equal({password: "x"}, payload)
          assert_equal({authorization: "Bearer abc"}, named_tags)
        end

        it "keeps a field that has no sensitive key, and one that is nil" do
          payload     = {user: "jack"}
          log.payload = payload
          log.redact(redactor)

          assert_same payload, log.payload
          assert_nil log.context
          assert_nil log.dimensions
        end

        it "leaves the message, tags, and exception as they are" do
          log.message   = "password: x"
          log.tags      = ["password"]
          log.exception = exception
          log.redact(redactor)

          assert_equal "password: x", log.message
          assert_equal ["password"], log.tags
          assert_same exception, log.exception
        end

        it "returns the entry" do
          assert_same log, log.redact(redactor)
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
