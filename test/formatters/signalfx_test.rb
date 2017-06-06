require_relative '../test_helper'
require 'net/http'

module SemanticLogger
  module Formatters
    class SignalfxTest < Minitest::Test
      describe SemanticLogger::Formatters::Signalfx do
        let :fixed_metric do
          'user.login'
        end

        let :log do
          metric     = '/user/login'
          log        = SemanticLogger::Log.new('User', :debug)
          log.metric = metric
          log
        end

        let :logs do
          3.times.collect do |i|
            l        = log.dup
            l.metric = "/user/login#{i+1}"
            l
          end
        end

        let :same_logs do
          3.times.collect do |i|
            l        = log.dup
            l.metric = "/user/login"
            l
          end
        end

        let :appender do
          Net::HTTP.stub_any_instance(:start, true) do
            SemanticLogger::Appender::Signalfx.new(token: 'TEST')
          end
        end

        let :formatter do
          appender.formatter
        end

        describe 'format single log' do
          let :result do
            JSON.parse(formatter.call(log, appender))
          end

          it 'send counter metric when there is no duration' do
            hash = result
            assert counters = hash['counter'], hash
            assert counter = counters.first, hash
            assert_equal fixed_metric, counter['metric'], counter
            assert_equal 1, counter['value'], counter
            assert_equal (log.time.to_f * 1_000).to_i, counter['timestamp'], counter
            assert counter.has_key?('dimensions')
          end

          it 'send gauge metric when log includes duration' do
            log.duration = 1234
            hash         = result
            assert counters = hash['gauge'], hash
            assert counter = counters.first, hash
            assert_equal fixed_metric, counter['metric'], counter
            assert_equal 1234, counter['value'], counter
            assert_equal (log.time.to_f * 1_000).to_i, counter['timestamp'], counter
            assert counter.has_key?('dimensions')
          end

          it 'only forwards whitelisted dimensions' do
            log.named_tags       = {user_id: 47, application: 'sample', tracking_number: 7474, session_id: 'hsdhngsd'}
            formatter.dimensions = [:user_id, :application]
            hash                 = result
            assert counters = hash['counter'], hash
            assert counter = counters.first, hash
            assert_equal({'user_id' => '47', 'host' => SemanticLogger.host, 'application' => 'sample'}, counter['dimensions'], counter)
          end

          it 'raises exception with both a whitelist and blacklist' do
            assert_raises ArgumentError do
              SemanticLogger::Formatters::Signalfx.new(token: 'TEST', dimensions: [:user_id], exclude_dimensions: [:tracking_number])
            end
          end
        end

        describe 'format batch logs' do
          let :result do
            JSON.parse(formatter.batch(logs, appender))
          end

          it 'send metrics' do
            hash = result

            assert counters = hash['counter'], hash
            assert_equal 3, counters.size
            assert_equal 'user.login1', counters[0]['metric']
            assert_equal 1, counters[0]['value']
            assert_equal 'user.login2', counters[1]['metric']
            assert_equal 'user.login3', counters[2]['metric']
          end
        end

        describe 'format batch logs with aggregation' do
          let :result do
            JSON.parse(formatter.batch(same_logs, appender))
          end

          it 'send metrics' do
            hash = result

            assert counters = hash['counter'], hash
            assert_equal 1, counters.size
            assert_equal 'user.login', counters[0]['metric']
            assert_equal 3, counters[0]['value']
          end
        end

      end

    end
  end
end
