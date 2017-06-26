require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Honeybadger
module Appender
  class HoneybadgerTest < Minitest::Test
    # Assume the formatter is well tested
    describe SemanticLogger::Appender::Honeybadger do
      before do
        @appender                      = SemanticLogger::Appender::Honeybadger.new(level: :trace)
        @message                       = 'AppenderHoneybadgerTest log message'
        SemanticLogger.backtrace_level = :error
      end

        appender = SemanticLogger::Appender::Honeybadger.new(level: :trace, formatter: lambda { |_, _| formatted.dup })
        hash = nil
        context = nil
        request = nil

        stubbed_notify = lambda do |h|
          request = Honeybadger::Agent.config.request
          context = Honeybadger.get_context
          hash = h
        end

        Honeybadger.stub(:notify, stubbed_notify) do
          appender.log(SemanticLogger::Log.new)
        end

        assert_equal formatted.delete(:request), request
        assert_equal formatted.delete(:context), context
        assert_equal formatted, hash
      end

      it 'should use a SemanticLogger::Formatters::Honeybadger formatter by default' do
        assert SemanticLogger::Appender::Honeybadger.new.formatter.is_a?(SemanticLogger::Formatters::Honeybadger)
      end
    end
  end
end
