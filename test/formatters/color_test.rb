require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class ColorTest < Minitest::Test
      describe Color do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          # :level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index, :exception, :metric, :backtrace, :metric_amount, :named_tags
          log      = SemanticLogger::Log.new("ColorTest", level)
          log.time = log_time
          log
        end

        let(:expected_time) do
          SemanticLogger::Formatters::Base::PRECISION == 3 ? "2017-01-14 08:32:05.375" : "2017-01-14 08:32:05.375276"
        end

        let(:set_exception) do
          begin
            raise "Oh no"
          rescue Exception => e
            log.exception = e
          end
        end

        let(:backtrace) do
          [
            "test/formatters/default_test.rb:35:in `block (2 levels) in <class:DefaultTest>'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `instance_eval'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `block (2 levels) in let'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `fetch'",
            "ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `block in let'",
            "test/formatters/default_test.rb:65:in `block (3 levels) in <class:DefaultTest>'",
            "ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/test.rb:105:in `block (3 levels) in run'"
          ]
        end

        let(:bold) do
          SemanticLogger::AnsiColors::BOLD
        end

        let(:clear) do
          SemanticLogger::AnsiColors::CLEAR
        end

        let(:color) do
          SemanticLogger::AnsiColors::GREEN
        end

        let(:formatter) do
          formatter = SemanticLogger::Formatters::Color.new
          # Does not use the logger instance for formatting purposes
          formatter.call(log, nil)
          formatter
        end

        describe "level" do
          it "logs single character" do
            assert_equal "#{color}D#{clear}", formatter.level
          end
        end

        describe "tags" do
          it "logs tags" do
            log.tags = %w[first second third]
            assert_equal "[#{color}first#{clear}] [#{color}second#{clear}] [#{color}third#{clear}]", formatter.tags
          end
        end

        describe "named_tags" do
          it "logs named tags" do
            log.named_tags = {first: 1, second: 2, third: 3}
            assert_equal "{#{color}first: 1#{clear}, #{color}second: 2#{clear}, #{color}third: 3#{clear}}", formatter.named_tags
          end
        end

        describe "duration" do
          it "logs long duration" do
            log.duration = 1_000_000.34567
            assert_equal "(#{bold}16m 40s#{clear})", formatter.duration
          end

          it "logs short duration" do
            log.duration = 1.34567
            duration     = SemanticLogger::Formatters::Base::PRECISION == 3 ? "(#{bold}1ms#{clear})" : "(#{bold}1.346ms#{clear})"
            assert_equal duration, formatter.duration
          end
        end

        describe "name" do
          it "logs name" do
            assert_equal "#{color}ColorTest#{clear}", formatter.name
          end
        end

        describe "payload" do
          it "logs hash payload" do
            log.payload = {first: 1, second: 2, third: 3}
            assert_equal "-- #{log.payload.ai(multiline: false)}", formatter.payload
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
            str = "-- Exception: #{color}RuntimeError: Oh no#{clear}\n"
            assert_equal str, formatter.exception.lines.first
          end

          it "skips nil exception" do
            refute formatter.exception
          end
        end

        describe "call" do
          it "returns minimal elements" do
            assert_equal "#{expected_time} #{color}D#{clear} [#{$$}:#{Thread.current.name}] #{color}ColorTest#{clear}", formatter.call(log, nil)
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
            str      = "#{expected_time} #{color}D#{clear} [#{$$}:#{Thread.current.name} default_test.rb:35] [#{color}first#{clear}] [#{color}second#{clear}] [#{color}third#{clear}] {#{color}first: 1#{clear}, #{color}second: 2#{clear}, #{color}third: 3#{clear}} (#{bold}#{duration}ms#{clear}) #{color}ColorTest#{clear} -- Hello World -- #{{first: 1, second: 2, third: 3}.ai(multiline: false)} -- Exception: #{color}RuntimeError: Oh no#{clear}\n"
            assert_equal str, formatter.call(log, nil).lines.first
          end
        end
      end
    end
  end
end
