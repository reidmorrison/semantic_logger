require_relative '../test_helper'

# Unit Test for SemanticLogger::Formatters::Honeybadger
module Formatters
  class HoneybadgerTest < Minitest::Test
    describe SemanticLogger::Formatters::Honeybadger do
      before do
        @appender = SemanticLogger::Appender::Honeybadger.new
        @formatter = SemanticLogger::Formatters::Honeybadger.new
        @log = SemanticLogger::Log.new(:trace, Time.now.to_f.to_s, 'name', 'message', property: 1)
        @thread = Thread.new { sleep }
        @thread.name = @log.thread_name
      end

      after do
        @thread.kill
      end

      it 'should not have any context if there was no caller thread' do
        @log.thread_name = nil
        context = @formatter.call(@log, @appender)
        expected = @formatter.class.superclass.new.call(@log, @appender)
        assert_equal expected, context, 'Should be the same has its parent class'
      end

      it 'should not have any context if the caller thread had no honeybadger context' do
        context = @formatter.call(@log, @appender)
        expected = @formatter.class.superclass.new.call(@log, @appender)
        assert_equal expected, context, 'Should be the same has its parent class'
      end

      it 'should not add anything if the Honeybadger context is of an unexpected format' do
        @thread[@formatter.class::CONTEXT_KEY] = 1

        context = @formatter.call(@log, @appender)
        expected = @formatter.class.superclass.new.call(@log, @appender)
        assert_equal expected, context, 'Should be the same has its parent class'
      end

      it 'should add the Honeybadger context when it is available from the caller thread' do
        request = FakeRequest.new
        @thread[@formatter.class::CONTEXT_KEY] = request

        context = @formatter.call(@log, @appender)
        expected = @formatter.class.superclass.new.call(@log, @appender).merge(
          url: request.url,
          component: nil,
          action: nil,
          params: { paramA: 1 },
          session: { sessionA: 1 },
          cgi_data: {}
        )
        assert_equal expected, context, 'Should be the same has its parent class'
      end
    end

    # More accurate would be to add Rack as a dependency and use a Rack::Request, but I'm not too sure about adding
    # a dependency just for that
    class FakeRequest
      def env
        {
          'honeybadger.request.url' => url
        }
      end

      def url
        'http://my.rails.app/controller/action'
      end

      def params
        FakeParams.new
      end

      def session
        FakeSession.new
      end

      class FakeParams
        def to_hash
          { paramA: 1 }
        end
      end

      class FakeSession
        def to_hash
          { sessionA: 1 }
        end
      end
    end
  end
end
