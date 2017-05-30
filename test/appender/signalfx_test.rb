require_relative '../test_helper'

module Appender
  class SignalfxTest < Minitest::Test
    describe SemanticLogger::Appender::Signalfx do
      before do
        @metric       = '/user/login'
        @fixed_metric = 'user.login'
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

      describe 'formatter' do
        let :formatter do
          SemanticLogger::Formatters::Signalfx.new(token: 'TEST')
        end

        let :result do
          JSON.parse(formatter.call(@log, appender))
        end

        it 'send counter metric when there is no duration' do
          hash = result
          assert counters = hash['counter'], hash
          assert counter = counters.first, hash
          assert_equal @fixed_metric, counter['metric'], counter
          assert_equal 1, counter['value'], counter
          assert_equal (@log.time.to_f * 1_000).to_i, counter['timestamp'], counter
          refute counter.has_key?('dimensions')
        end

        it 'send gauge metric when log includes duration' do
          @log.duration = 1234
          hash          = result
          assert counters = hash['gauge'], hash
          assert counter = counters.first, hash
          assert_equal @fixed_metric, counter['metric'], counter
          assert_equal 1234, counter['value'], counter
          assert_equal (@log.time.to_f * 1_000).to_i, counter['timestamp'], counter
          refute counter.has_key?('dimensions')
        end

        it 'whitelists dimensions' do
          @log.named_tags              = {user_id: 47, application: 'sample', tracking_number: 7474, session_id: 'hsdhngsd'}
          formatter.include_dimensions = [:user_id, :application]
          hash                         = result
          assert counters = hash['counter'], hash
          assert counter = counters.first, hash
          assert_equal({'user_id' => '47', 'application' => 'sample'}, counter['dimensions'], counter)
        end

        it 'blacklists dimensions' do
          @log.named_tags              = {user_id: 47, application: 'sample', tracking_number: 7474, session_id: 'hsdhngsd'}
          formatter.exclude_dimensions = [:tracking_number, :session_id]
          hash                         = result
          assert counters = hash['counter'], hash
          assert counter = counters.first, hash
          assert_equal({'user_id' => '47', 'application' => 'sample'}, counter['dimensions'], counter)
        end

        it 'raises exception with both a whitelist and blacklist' do
          assert_raises ArgumentError do
            SemanticLogger::Formatters::Signalfx.new(token: 'TEST', include_dimensions: [:user_id], exclude_dimensions: [:tracking_number])
          end
        end

      end


      describe 'http call' do
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
          @log.named_tags              = {user_id: 47, application: 'sample', tracking_number: 7474, session_id: 'hsdhngsd'}
          appender.formatter.include_dimensions = [:user_id, :application]
          assert response
        end

        it 'blacklists dimensions' do
          @log.named_tags              = {user_id: 47, application: 'sample', tracking_number: 7474, session_id: 'hsdhngsd'}
          appender.formatter.exclude_dimensions = [:tracking_number, :session_id]
          assert response
        end
      end

    end
  end
end
