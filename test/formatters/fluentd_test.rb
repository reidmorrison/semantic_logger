require_relative '../test_helper'

module SemanticLogger
  module Formatters
    class FluentdTest < Minitest::Test
      describe Fluentd  do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          # :level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index, :exception, :metric, :backtrace, :metric_amount, :named_tags
          log      = SemanticLogger::Log.new('FluentdTest', level)
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
          formatter = SemanticLogger::Formatters::Fluentd.new(log_host: false, log_application: false)
          # Does not use the logger instance for formatting purposes
          formatter.call(log, nil)
          formatter
        end

        describe 'severity' do
          it 'logs single character' do
            assert_equal 1, formatter.level
          end
        end

        describe 'name' do
          it 'logs name' do
            assert_equal 'FluentdTest', formatter.name
          end
        end

       describe 'call' do
         it 'logs single-line json'do
           log.tags       = %w[first second third]
           log.named_tags = {first: 1, second: 2, third: 3}
           log.message    = 'Hello World'
           log.payload    = {first: 1, second: 2, third: 3}
           set_exception
           str = JSON.parse(formatter.call(log, nil))
           assert_equal str["exception"]["name"], 'RuntimeError'
         end
       end
      end
    end
  end
end
