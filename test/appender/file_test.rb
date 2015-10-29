require_relative '../test_helper'
require 'stringio'

# Unit Test for SemanticLogger::Appender::File
#
module Appender
  class FileTest < Minitest::Test
    describe SemanticLogger::Appender::File do
      before do
        SemanticLogger.default_level = :trace
        @time                        = Time.new
        @io                          = StringIO.new
        @appender                    = SemanticLogger::Appender::File.new(@io)
        @hash                        = {session_id: 'HSSKLEU@JDK767', tracking_number: 12345}
        @hash_str                    = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
        @thread_name                 = Thread.current.name
      end

      describe 'format logs into text form' do
        it 'handle no message or payload' do
          @appender.debug
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- \n/, @io.string
        end

        it 'handle message' do
          @appender.debug 'hello world'
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- hello world\n/, @io.string
        end

        it 'handle message and payload' do
          @appender.debug 'hello world', @hash
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- hello world -- #{@hash_str}\n/, @io.string
        end

        it 'handle message, payload, and exception' do
          @appender.debug 'hello world', @hash, StandardError.new('StandardError')
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- hello world -- #{@hash_str} -- Exception: StandardError: StandardError\n\n/, @io.string
        end

        it 'handle exception only' do
          @appender.debug StandardError.new('StandardError')
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- #<StandardError: StandardError> -- Exception: StandardError: StandardError\n\n/, @io.string
        end
      end

      describe 'for each log level' do
        # Ensure that any log level can be logged
        SemanticLogger::LEVELS.each do |level|
          it "log #{level} information" do
            @appender.send(level, 'hello world', @hash)
            assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- hello world -- #{@hash_str}\n/, @io.string
          end
        end
      end

      describe 'custom formatter' do
        before do
          @appender = SemanticLogger::Appender::File.new(@io) do |log|
            tags = log.tags.collect { |tag| "[#{tag}]" }.join(' ') + ' ' if log.tags && (log.tags.size > 0)

            message = log.message.to_s
            message << ' -- ' << log.payload.inspect if log.payload
            message << ' -- ' << "#{log.exception.class}: #{log.exception.message}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

            duration_str = log.duration ? " (#{'%.1f' % log.duration}ms)" : ''

            "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{log.level.to_s.upcase} [#{$$}:#{log.thread_name}] #{tags}#{log.name} -- #{message}#{duration_str}"
          end
        end

        it 'format using formatter' do
          @appender.debug
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ DEBUG \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- \n/, @io.string
        end
      end

    end
  end
end
