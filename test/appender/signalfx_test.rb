require_relative '../test_helper'

module Appender
  class SignalfxTest < Minitest::Test
    describe SemanticLogger::Appender::Signalfx do
      before do
        @metric       = '/user/login'
        @log          = SemanticLogger::Log.new('User', :debug)
        @log.metric   = @metric
      end

      let :appender do
        if ENV['SIGNALFX_TOKEN']
          SemanticLogger::Appender::Signalfx.new(token: ENV['SIGNALFX_TOKEN'])
        else
          Net::HTTP.stub_any_instance(:start, true) do
            @appender = SemanticLogger::Appender::Signalfx.new(token: 'TEST')
          end
        end
      end

      describe 'log message' do
        let :response do
          # Do not stub if the token is available in the environment
          if ENV['SIGNALFX_TOKEN']
            appender.log(@log)
          else
            response_mock = Struct.new(:code, :body)
            request       = nil
            appender.http.stub(:request, -> r { request = r; response_mock.new('200', 'ok') }) do
              appender.log(@log)
            end
          end
        end

        it 'send counter metric when there is no duration' do
          assert response
        end

        it 'send gauge metric when log includes duration' do
          @log.duration = 1234
          assert response
        end

        it 'whitelists dimensions' do
          @log.named_tags                       = {user_id: 47, application: 'sample', tracking_number: 7474, session_id: 'hsdhngsd'}
          appender.formatter.include_dimensions = [:user_id, :application]
          assert response
        end
      end

    end
  end
end
