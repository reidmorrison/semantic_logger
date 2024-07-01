require_relative "../test_helper"
require "syslog"

module SemanticLogger
  module Formatters
    class SyslogCeeTest < Minitest::Test
      describe SyslogCee do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          # :level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index, :exception, :metric, :backtrace, :metric_amount, :named_tags
          log      = SemanticLogger::Log.new("SyslogCeeTest", level)
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

        let(:appender) do
          SemanticLogger::Appender::Syslog.new(formatter: :syslog_cee)
        end

        let(:formatter) do
          formatter = appender.formatter
          formatter.max_size = appender.max_size
          # We need to use logger to test this formatter
          formatter.call(log, appender.logger)
          formatter
        end

        describe "name" do
          it "logs name" do
            assert_equal "SyslogCeeTest", formatter.name
          end
        end

        describe "call" do
          it "uses CEE format" do
            assert_match(/@cee:/, formatter.call(log, appender.logger))
          end

          it "process log with payload" do
            log.payload = {is_test: true}
            assert_match(/"is_test":true/, formatter.call(log, appender.logger))
          end

          it "includes host name" do
            formatted_log = formatter.call(log, appender.logger)
            assert_equal true, formatted_log.include?(appender.logger.host)
          end

          it "includes application name" do
            formatted_log = formatter.call(log, appender.logger)
            assert_equal true, formatted_log.include?(appender.logger.application)
          end

          it "includes environment" do
            formatted_log = formatter.call(log, appender.logger)
            assert_equal true, formatted_log.include?(appender.logger.environment)
          end

          it "includes correct log level" do
            assert_match(/"level":"debug"/, formatter.call(log, appender.logger))
          end

          describe "when exception was raised" do
            it "logs exception name" do
              set_exception
              assert_match(/"name":"RuntimeError"/, formatter.call(log, appender.logger))
            end

            it "logs exception message" do
              set_exception
              assert_match(/"message":"Oh no"/, formatter.call(log, appender.logger))
            end
          end
        end
      end
    end
  end
end
