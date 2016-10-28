require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::MongoDB
#
module Appender
  class RedisTest < Minitest::Test
    describe SemanticLogger::Appender::Redis do
      before do
        @db_rx                 = Redis.new
        @db_tx                 = Redis.new
        @appender           = SemanticLogger::Appender::Redis.new(
          db:              @db_tx,
        )
        @hash               = {session_id: 'HSSKLEU@JDK767', tracking_number: 12345}
      end

      after do
        @appender.purge_all if @appender
      end

      describe 'format logs into json' do
        it 'handle no arguments' do
          json = nil
          t_rx = Thread.new {
            begin
              @db_rx.subscribe('debug') do |on|
                on.message do |channel, log|
                  json = JSON.parse(log)
                  Thread.exit
                end
              end
            rescue
              assert_equal(1,0,'Redis subscribe thread failed to start!')
            end
          }
          
          t_snd = Thread.new{
            for i in 1..5 
              @thread_name = Thread.current.name
              @appender.debug
              Thread.pass
              sleep 0.5 
            end
          }
          t_rx.join(10)
          t_snd.kill
          assert json != nil
          assert_match('SemanticLogger::Appender::Redis', json["name"])
          assert_match(@thread_name, json["thread"])
          assert_match('debug', json["level"])
          assert_match('Semantic Logger', json["application"])
        end

        it 'handle message' do
          json = nil
          t_rx = Thread.new {
            begin
              @db_rx.subscribe('debug') do |on|
                on.message do |channel, log|
                  json = JSON.parse(log)
                  Thread.exit
                end
              end
            rescue
              assert_equal(1,0,'Redis subscribe thread failed to start!')
            end
          }
          
          t_snd = Thread.new{
            for i in 1..5 
              @thread_name = Thread.current.name
              @appender.debug 'hello world'
              Thread.pass
              sleep 0.5 
            end
          }
          t_rx.join(10)
          t_snd.kill
          assert json != nil
          assert_match('SemanticLogger::Appender::Redis', json["name"])
          assert_match(@thread_name, json["thread"])
          assert_match('debug', json["level"])
          assert_match('Semantic Logger', json["application"])
          assert_match('hello world', json['message'])
        end

        it 'handle message, payload, and exception' do
          json = nil
          t_rx = Thread.new {
            begin
              @db_rx.subscribe('debug') do |on|
                on.message do |channel, log|
                  json = JSON.parse(log)
                  Thread.exit
                end
              end
            rescue
              assert_equal(1,0,'Redis subscribe thread failed to start!')
            end
          }
          
          t_snd = Thread.new{
            for i in 1..5 
              @thread_name = Thread.current.name
              @appender.debug 'hello world', @hash, StandardError.new('StandardError')
              Thread.pass
              sleep 0.5 
            end
          }
          t_rx.join(10)
          t_snd.kill
          assert json != nil
          assert_match('hello world', json['message'])
          assert_match(@hash[:session_id], json['session_id'])
          assert_equal(@hash[:tracking_number], json['tracking_number'])
          assert_match('StandardError', json['exception']['name'])
        end
      end

      describe 'for each log level' do
        # Ensure that any log level can be logged
        SemanticLogger::LEVELS.each do |level|
          it 'log #{level} information' do
            json = nil
            t_rx = Thread.new {
              begin
                @db_rx.subscribe(level) do |on|
                  on.message do |channel, log|
                    json = JSON.parse(log)
                    Thread.exit
                  end
                end
              rescue
                assert_equal(1,0,'Redis subscribe thread failed to start!')
              end
            }
            
            t_snd = Thread.new{
              for i in 1..5 
                @thread_name = Thread.current.name
                @appender.send(level, 'hello world -- Calculations', @hash)
                Thread.pass
                sleep 0.5 
              end
            }
            t_rx.join(10)
            t_snd.kill
            assert json != nil
            assert_match('hello world -- Calculations', json['message'])
            assert_match(level.to_s, json['level'])
          end
        end

      end

    end
  end
end
