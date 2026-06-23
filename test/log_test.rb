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

          it "coerces a non-exception into an ArgumentError" do
            log.assign(exception: "not an exception")

            assert_kind_of ArgumentError, log.exception
            assert_match(/Invalid value for logger exception/, log.exception.message)
          end

          it "changes the level when on_exception_level is supplied" do
            log.assign(exception: exception, on_exception_level: :fatal)

            assert_equal :fatal, log.level
            assert_equal SemanticLogger::Levels.index(:fatal), log.level_index
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
