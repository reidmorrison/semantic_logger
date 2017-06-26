require_relative '../test_helper'

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
          # :level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index, :exception, :metric, :backtrace, :metric_amount, :named_tags
          log      = SemanticLogger::Log.new('DefaultTest', level)
          log.time = log_time
          log
        end

        let(:expected_time) do
          SemanticLogger::Formatters::Base::PRECISION == 3 ? '2017-01-14 08:32:05.375' : '2017-01-14 08:32:05.375276'
        end

        let(:set_exception) do
          begin
            raise 'Oh no'
          rescue Exception => exc
            log.exception = exc
          end
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

        let(:formatter) do
          formatter = SemanticLogger::Formatters::Default.new
          # Does not use the logger instance for formatting purposes
          formatter.call(log, nil)
          formatter
        end

        describe 'time' do
          it 'logs time' do
            assert_equal expected_time, formatter.time
          end

          it 'supports time_format' do
            formatter = SemanticLogger::Formatters::Default.new(time_format: "%H:%M:%S")
            formatter.call(log, nil)
            assert_equal '08:32:05', formatter.time
          end
        end

        describe 'level' do
          it 'logs single character' do
            assert_equal 'D', formatter.level
          end
        end

        describe 'process_info' do
          it 'logs pid and thread name' do
            assert_equal "[#{$$}:#{Thread.current.name}]", formatter.process_info
          end

          it 'logs pid, thread name, and file name' do
            set_exception
            log.backtrace = backtrace
            assert_equal "[#{$$}:#{Thread.current.name} default_test.rb:99]", formatter.process_info
          end
        end

        describe 'tags' do
          it 'logs tags' do
            log.tags = %w(first second third)
            assert_equal "[first] [second] [third]", formatter.tags
          end
        end

        describe 'named_tags' do
          it 'logs named tags' do
            log.named_tags = {first: 1, second: 2, third: 3}
            assert_equal "{first: 1, second: 2, third: 3}", formatter.named_tags
          end
        end

        describe 'duration' do
          it 'logs long duration' do
            log.duration = 1_000_000.34567
            assert_equal "(16m 40s)", formatter.duration
          end

          it 'logs short duration' do
            log.duration = 1.34567
            duration     = SemanticLogger::Formatters::Base::PRECISION == 3 ? "(1ms)" : "(1.346ms)"
            assert_equal duration, formatter.duration
          end
        end

        describe 'name' do
          it 'logs name' do
            assert_equal "DefaultTest", formatter.name
          end
        end

        describe 'message' do
          it 'logs message' do
            log.message = "Hello World"
            assert_equal "-- Hello World", formatter.message
          end

          it 'skips empty message' do
            refute formatter.message
          end
        end

        describe 'payload' do
          it 'logs hash payload' do
            log.payload = {first: 1, second: 2, third: 3}
            assert_equal "-- {:first=>1, :second=>2, :third=>3}", formatter.payload
          end

          it 'skips nil payload' do
            refute formatter.payload
          end

          it 'skips empty payload' do
            log.payload = {}
            refute formatter.payload
          end
        end

        describe 'exception' do
          it 'logs exception' do
            set_exception
            assert_match /-- Exception: RuntimeError: Oh no/, formatter.exception
          end

          it 'skips nil exception' do
            refute formatter.exception
          end
        end

        describe 'call' do
          it 'returns minimal elements' do
            assert_equal "#{expected_time} D [#{$$}:#{Thread.current.name}] DefaultTest", formatter.call(log, nil)
          end

          it 'retuns all elements' do
            log.tags       = %w(first second third)
            log.named_tags = {first: 1, second: 2, third: 3}
            log.duration   = 1.34567
            log.message    = "Hello World"
            log.payload    = {first: 1, second: 2, third: 3}
            log.backtrace  = backtrace
            set_exception
            duration = SemanticLogger::Formatters::Base::PRECISION == 3 ? '1' : '1.346'
            str      = "#{expected_time} D [#{$$}:#{Thread.current.name} default_test.rb:99] [first] [second] [third] {first: 1, second: 2, third: 3} (#{duration}ms) DefaultTest -- Hello World -- {:first=>1, :second=>2, :third=>3} -- Exception: RuntimeError: Oh no\n"
            assert_equal str, formatter.call(log, nil).lines.first
          end
        end

      end
    end
  end
end
