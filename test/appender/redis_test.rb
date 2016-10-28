require_relative '../test_helper'
require 'time'

# Unit Test for SemanticLogger::Appender::MongoDB
#
module Appender
  class RedisTest < Minitest::Test
    describe SemanticLogger::Appender::Redis do
      before do
        @db                 = Redis.new
        @appender           = SemanticLogger::Appender::Redis.new(
          db:              @db,
        )
        @hash               = {session_id: 'HSSKLEU@JDK767', tracking_number: 12345}
        @thread_name = Thread.current.name
      end

      after do
        @appender.purge_all if @appender
      end

      describe 'format logs into json' do
        it 'handle no arguments' do
          @appender.debug
          log = @db.lpop "debug"
          json = JSON.parse(log)
          assert_match('SemanticLogger::Appender::Redis', json["name"])
          assert_match(@thread_name, json["thread"])
          assert_match('debug', json["level"])
          assert_match('Semantic Logger', json["application"])
        end

        it 'handle message' do
          @appender.debug 'hello world'
          log = @db.lpop 'debug'
          json = JSON.parse(log)
          assert_match('hello world', json['message'])
        end

        it 'handle message, payload, and exception' do
          @appender.debug 'hello world', @hash, StandardError.new('StandardError')
          log = @db.lpop 'debug'
          json = JSON.parse(log)
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
            @appender.send(level, 'hello world -- Calculations', @hash)
            json = JSON.parse(@db.lpop level)
            assert_match('hello world -- Calculations', json['message'])
            assert_match(level.to_s, json['level'])
          end
        end

      end

    end
  end
end
