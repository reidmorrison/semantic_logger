require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class DefaultTest < Minitest::Test
      describe Default do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          # :level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index,
          # :exception, :metric, :backtrace, :metric_amount, :named_tags
          log      = SemanticLogger::Log.new("DefaultTest", level)
          log.time = log_time
          log
        end

        let(:expected_time) do
          SemanticLogger::Formatters::Base::PRECISION == 3 ? "2017-01-14 08:32:05.375" : "2017-01-14 08:32:05.375276"
        end

        let(:set_exception) do
          raise "Oh no"
        rescue Exception => e
          log.exception = e
        end

        let(:backtrace) do
          [
            "test/formatters/default_test.rb:99:in `block (2 levels) in <class:DefaultTest>'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `instance_eval'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `block (2 levels) in let'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `fetch'",
            "ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `block in let'",
            "test/formatters/default_test.rb:65:in `block (3 levels) in <class:DefaultTest>'",
            "ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/test.rb:105:in `block (3 levels) in run'"
          ]
        end

        # An object whose #inspect returns control characters, as a custom payload object can.
        let(:control_inspect) do
          object = Object.new
          object.define_singleton_method(:inspect) { "bob\nforged\e[2J" }
          object
        end

        let(:formatter) do
          formatter = SemanticLogger::Formatters::Default.new
          # Does not use the logger instance for formatting purposes
          formatter.call(log, nil)
          formatter
        end

        describe "time" do
          it "logs time" do
            assert_equal expected_time, formatter.time
          end

          it "supports time_format" do
            formatter = SemanticLogger::Formatters::Default.new(time_format: "%H:%M:%S")
            formatter.call(log, nil)

            assert_equal "08:32:05", formatter.time
          end

          it "supports time_format of iso_8601" do
            formatter = SemanticLogger::Formatters::Default.new(time_format: :iso_8601)
            formatter.call(log, nil)

            assert_equal "2017-01-14T08:32:05.375276Z", formatter.time
          end

          describe "precision is specified" do
            it "follows it for default time format" do
              formatter = SemanticLogger::Formatters::Default.new(precision: 2)
              formatter.call(log, nil)

              assert_equal "2017-01-14 08:32:05.37", formatter.time
            end

            it "follows it for iso_8601" do
              formatter = SemanticLogger::Formatters::Default.new(precision:   2,
                                                                  time_format: :iso_8601)
              formatter.call(log, nil)

              assert_equal "2017-01-14T08:32:05.37Z", formatter.time
            end
          end
        end

        describe "level" do
          it "logs single character" do
            assert_equal "D", formatter.level
          end
        end

        describe "process_info" do
          it "logs pid and thread name" do
            assert_equal "[#{$$}:#{log.thread_name}]", formatter.process_info
          end

          it "logs pid, thread name, and file name" do
            set_exception
            log.backtrace = backtrace

            assert_equal "[#{$$}:#{log.thread_name} default_test.rb:99]", formatter.process_info
          end
        end

        describe "tags" do
          it "logs tags" do
            log.tags = %w[first second third]

            assert_equal "[first] [second] [third]", formatter.tags
          end
        end

        describe "named_tags" do
          it "logs named tags" do
            log.named_tags = {first: 1, second: 2, third: 3}

            assert_equal "{first: 1, second: 2, third: 3}", formatter.named_tags
          end
        end

        describe "duration" do
          it "logs long duration" do
            log.duration = 1_000_000.34567

            assert_equal "(16m 40s)", formatter.duration
          end

          it "logs short duration" do
            log.duration = 1.34567
            duration     = SemanticLogger::Formatters::Base::PRECISION == 3 ? "(1ms)" : "(1.346ms)"

            assert_equal duration, formatter.duration
          end
        end

        describe "name" do
          it "logs name" do
            assert_equal "DefaultTest", formatter.name
          end
        end

        describe "message" do
          it "logs message" do
            log.message = "Hello World"

            assert_equal "-- Hello World", formatter.message
          end

          it "skips empty message" do
            refute formatter.message
          end

          it "preserves control characters by default" do
            log.message = "Hello\nInjected line\e[31m"

            assert_equal "-- Hello\nInjected line\e[31m", formatter.message
          end
        end

        describe "escape_control_chars" do
          let(:formatter) do
            formatter = SemanticLogger::Formatters::Default.new(escape_control_chars: true)
            formatter.call(log, nil)
            formatter
          end

          it "escapes newlines and ANSI escapes in the message" do
            log.message = "Hello\nInjected line\e[31m"

            assert_equal "-- Hello\\nInjected line\\e[31m", formatter.message
          end

          it "escapes the file name of a supplied backtrace" do
            log.backtrace = ["\e]0;owned\a\e[2J\rFAKE x.rb:1"]

            assert_equal "\\e]0;owned\\x07\\e[2J\\rFAKE x.rb:1", formatter.file_name_and_line
            assert_includes formatter.process_info, "\\e]0;owned\\x07\\e[2J\\rFAKE x.rb:1"
          end

          it "escapes carriage returns, tabs, and other control characters" do
            log.message = "a\rb\tc\x00d"

            assert_equal "-- a\\rb\\tc\\x00d", formatter.message
          end

          it "escapes control characters in tags" do
            injected = "bad\ninjected"
            log.tags = ["good", injected]

            assert_equal "[good] [bad\\ninjected]", formatter.tags
          end

          it "escapes control characters in named tags" do
            log.named_tags = {user: "bad\nname"}

            assert_equal "{user: bad\\nname}", formatter.named_tags
          end

          it "escapes control characters in the exception message" do
            begin
              raise "boom\ninjected"
            rescue StandardError => e
              log.exception = e
            end

            assert_match(/-- Exception: RuntimeError: boom\\ninjected/, formatter.exception)
          end

          it "escapes control characters in the message of each cause" do
            forged = "2026-10-03 00:00:00.000000 I [1:main] Auth -- admin logged in"
            begin
              begin
                raise ArgumentError, "bad input\n#{forged}"
              rescue ArgumentError
                raise "Request failed"
              end
            rescue StandardError => e
              log.exception = e
            end

            output = formatter.exception

            assert_includes output, "Cause: ArgumentError: bad input\\n#{forged}"
            refute(output.lines.any? { |line| line.start_with?(forged) }, "cause message forged a log line")
          end

          it "escapes control characters in each backtrace line" do
            begin
              begin
                raise ArgumentError, "inner"
              rescue ArgumentError
                raise "outer"
              end
            rescue StandardError => e
              e.set_backtrace(["app.rb:2\nforged outer", "app.rb:3"])
              e.cause.set_backtrace(["(\e[2J):1"])
              log.exception = e
            end

            assert_equal "-- Exception: RuntimeError: outer\n" \
                         "app.rb:2\\nforged outer\napp.rb:3\n" \
                         "Cause: ArgumentError: inner\n(\\e[2J):1",
                         formatter.exception
          end

          it "drops invalid UTF-8 from the message of a cause instead of failing" do
            begin
              begin
                raise ArgumentError, "bad \xff\ninput"
              rescue ArgumentError
                raise "wrapped"
              end
            rescue StandardError => e
              log.exception = e
            end

            assert_includes formatter.exception, "Cause: ArgumentError: bad \\ninput"
          end

          it "drops invalid UTF-8 from the exception message instead of failing" do
            begin
              raise "bad \xff\ninput"
            rescue StandardError => e
              log.exception = e
            end

            assert_match(/\A-- Exception: RuntimeError: bad \\ninput\n/, formatter.exception)
          end

          it "drops invalid UTF-8 from the message instead of failing" do
            log.message = "bad \xff\ninput"

            assert_equal "-- bad \\ninput", formatter.message
          end

          it "escapes control characters in the logger name" do
            log.name = "Auth\e[2J\nforged"

            assert_equal "Auth\\e[2J\\nforged", formatter.name
          end

          it "escapes control characters in the thread name" do
            log.thread_name = "worker\nforged"

            assert_equal "worker\\nforged", formatter.thread_name
            assert_equal "[#{$$}:worker\\nforged]", formatter.process_info
          end

          it "escapes control characters in the payload" do
            log.payload = {user: control_inspect}

            # Ruby 3.4 changed the way hashes are displayed
            if RUBY_VERSION < "3.4"
              assert_equal "-- {:user=>bob\\nforged\\e[2J}", formatter.payload
            else
              assert_equal "-- {user: bob\\nforged\\e[2J}", formatter.payload
            end
          end

          it "escapes the name, thread name, and payload of the whole entry" do
            log.name        = "Auth\nforged"
            log.thread_name = "worker\e[2J"
            log.message     = "Hello\nWorld"
            log.payload     = control_inspect

            assert_equal "#{expected_time} D [#{$$}:worker\\e[2J] Auth\\nforged -- Hello\\nWorld -- bob\\nforged\\e[2J",
                         formatter.call(log, nil)
          end

          it "preserves control characters in the whole entry when disabled" do
            log.name        = "Auth\nforged"
            log.thread_name = "worker\e[2J"
            log.message     = "Hello\nWorld"
            log.payload     = control_inspect

            assert_equal "#{expected_time} D [#{$$}:worker\e[2J] Auth\nforged -- Hello\nWorld -- bob\nforged\e[2J",
                         SemanticLogger::Formatters::Default.new.call(log, nil)
          end
        end

        describe "exception backtrace" do
          it "matches Log#backtrace_to_s when control characters are not escaped" do
            begin
              begin
                raise ArgumentError, "inner\nline"
              rescue ArgumentError
                raise "outer"
              end
            rescue StandardError => e
              log.exception = e
            end
            formatter.call(log, nil)

            assert formatter.exception.end_with?(log.backtrace_to_s)
          end

          describe "for a three deep chain" do
            before do
              begin
                begin
                  begin
                    raise ArgumentError, "root\ncause"
                  rescue ArgumentError => e
                    e.set_backtrace(%w[r1 r2])
                    raise
                  end
                rescue ArgumentError
                  raise IOError, "middle"
                end
              rescue IOError => e
                e.set_backtrace(%w[m1])
                raise "top"
              end
            rescue RuntimeError => e
              e.set_backtrace(%w[t1 t2])
              log.exception = e
            end

            it "lays out every exception unchanged when control characters are not escaped" do
              expected = "-- Exception: RuntimeError: top\n" \
                         "t1\nt2\nCause: IOError: middle\nm1\nCause: ArgumentError: root\ncause\nr1\nr2"

              assert_equal expected, formatter.exception
            end

            it "keeps the layout and escapes each cause when control characters are escaped" do
              formatter = SemanticLogger::Formatters::Default.new(escape_control_chars: true)
              formatter.call(log, nil)
              expected = "-- Exception: RuntimeError: top\n" \
                         "t1\nt2\nCause: IOError: middle\nm1\nCause: ArgumentError: root\\ncause\nr1\nr2"

              assert_equal expected, formatter.exception
            end
          end
        end

        describe "payload" do
          it "logs hash payload" do
            log.payload = {first: 1, second: 2, third: 3}

            # Ruby 3.4 changed the way hashes are displayed
            if RUBY_VERSION < "3.4"
              assert_equal "-- {:first=>1, :second=>2, :third=>3}", formatter.payload
            else
              assert_equal "-- {first: 1, second: 2, third: 3}", formatter.payload
            end
          end

          it "skips nil payload" do
            refute formatter.payload
          end

          it "skips empty payload" do
            log.payload = {}

            refute formatter.payload
          end
        end

        describe "exception" do
          it "logs exception" do
            set_exception

            assert_match(/-- Exception: RuntimeError: Oh no/, formatter.exception)
          end

          it "skips nil exception" do
            refute formatter.exception
          end
        end

        describe "call" do
          it "returns minimal elements" do
            assert_equal "#{expected_time} D [#{$$}:#{log.thread_name}] DefaultTest", formatter.call(log, nil)
          end

          it "retuns all elements" do
            log.tags       = %w[first second third]
            log.named_tags = {first: 1, second: 2, third: 3}
            log.duration   = 1.34567
            log.message    = "Hello World"
            log.payload    = {first: 1, second: 2, third: 3}
            log.backtrace  = backtrace
            set_exception
            duration = SemanticLogger::Formatters::Base::PRECISION == 3 ? "1" : "1.346"

            # Ruby 3.4 changed the way hashes are displayed
            str = if RUBY_VERSION < "3.4"
                    "#{expected_time} D [#{$$}:#{log.thread_name} default_test.rb:99] " \
                      "[first] [second] [third] {first: 1, second: 2, third: 3} " \
                      "(#{duration}ms) DefaultTest -- Hello World -- " \
                      "{:first=>1, :second=>2, :third=>3} -- Exception: RuntimeError: Oh no\n"
                  else
                    "#{expected_time} D [#{$$}:#{log.thread_name} default_test.rb:99] " \
                      "[first] [second] [third] {first: 1, second: 2, third: 3} " \
                      "(#{duration}ms) DefaultTest -- Hello World -- " \
                      "{first: 1, second: 2, third: 3} -- Exception: RuntimeError: Oh no\n"
                  end

            assert_equal str, formatter.call(log, nil).lines.first
          end
        end
      end
    end
  end
end
