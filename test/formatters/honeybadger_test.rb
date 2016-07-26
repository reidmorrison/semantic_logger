require_relative '../test_helper'

# Unit Test for SemanticLogger::Formatters::Honeybadger
module Formatters
  class HoneybadgerTest < Minitest::Test
    describe SemanticLogger::Formatters::Honeybadger do
      before do
        @appender = SemanticLogger::Appender::Honeybadger.new
        SemanticLogger.add_appender(@appender)
        @formatter = SemanticLogger::Formatters::Honeybadger.new
        @log = SemanticLogger::Log.new(:trace, Time.now.to_f.to_s, 'name', 'message', property: 1)
      end

      it 'should add basic info (tags, context, error_message, error_class) properly' do
        @log.tags = %w(a b)
        expected = { tags: @log.tags, context: SemanticLogger::Formatters::Raw.new.call(@log, @appender).select { |key| SemanticLogger::Formatters::Honeybadger::SEMANTIC_CONTEXT_KEYS.include?(key) }, error_message: @log.message, error_class: @log.name }
        assert_equal expected, @formatter.call(@log, @appender)
      end

      it 'should add the exception if there was one' do
        @log.exception = StandardError.new('test')
        expected = { tags: @log.tags, context: SemanticLogger::Formatters::Raw.new.call(@log, @appender).select { |key| SemanticLogger::Formatters::Honeybadger::SEMANTIC_CONTEXT_KEYS.include?(key) }, exception: @log.exception }
        assert_equal expected, @formatter.call(@log, @appender)
      end

      it 'should add the request if there was one' do
        @log.thread_context = { SemanticLogger::Formatters::Honeybadger::THREAD_VARIABLE_REQUEST => 'I am request' }
        formatted = @formatter.call(@log, @appender)
        assert_equal 'I am request', formatted[:request]
      end

      it 'should add the context if there was one' do
        @log.thread_context = { SemanticLogger::Formatters::Honeybadger::THREAD_VARIABLE_CONTEXT => 'I am context' }
        formatted = @formatter.call(@log, @appender)
        assert_equal 'I am context', formatted[:context][:honeybadger_context]

        @log.thread_context = { SemanticLogger::Formatters::Honeybadger::THREAD_VARIABLE_CONTEXT => { propertyA: 1 } }
        formatted = @formatter.call(@log, @appender)
        assert_equal 1, formatted[:context][:propertyA]
      end
    end
  end
end
