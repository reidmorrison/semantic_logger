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
        expected = { tags: @log.tags, context: SemanticLogger::Formatters::Raw.new.call(@log, @appender).reject { |key, _| [:name, :message].include?(key) }, error_message: @log.message, error_class: @log.name }
        assert_equal expected, @formatter.call(@log, @appender)
      end

      it 'should add the exception if there was one' do
        @log.exception = StandardError.new('test')
        expected = { tags: @log.tags, context: SemanticLogger::Formatters::Raw.new.call(@log, @appender).reject { |key, _| [:exception].include?(key) }, exception: @log.exception }
        assert_equal expected, @formatter.call(@log, @appender)
      end

      it 'should add the request if there was one' do
        @log.appender_context[@appender.class] = { request: 'I am request' }
        formatted = @formatter.call(@log, @appender)
        assert_equal 'I am request', formatted[:request]
      end

      it 'should add the context if there was one' do
        @log.appender_context[@appender.class] = { context: 'I am context' }
        formatted = @formatter.call(@log, @appender)
        assert_equal 'I am context', formatted[:context][:honeybadger]

        @log.appender_context[@appender.class] = { context: { propertyA: 1 } }
        formatted = @formatter.call(@log, @appender)
        assert_equal 1, formatted[:context][:propertyA]
      end
    end
  end
end
