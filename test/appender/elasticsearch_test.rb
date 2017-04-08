require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Elasticsearch
module Appender
  class ElasticsearchTest < Minitest::Test
    describe SemanticLogger::Appender::Elasticsearch do
      before do
        Elasticsearch::Transport::Client.stub_any_instance(:bulk, true) do
          @appender = SemanticLogger::Appender::Elasticsearch.new(
            url: 'http://localhost:9200',
            batch_size: 1 # immediate flush
          )
        end
        @message = 'AppenderElasticsearchTest log message'
      end

      after do
        @appender.close if @appender
      end

      it 'logs to daily indexes' do
        index = nil
        @appender.stub(:enqueue, ->(ind, json){ index = ind['index']['_index'] } ) do
          @appender.info @message
        end
        assert_equal "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}", index
      end

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          request = nil
          @appender.client.stub(:bulk, -> r { request = r; {"status" => 201 } }) do
            @appender.send(level, @message)
          end

          message = request[:body][1]
          assert_equal @message, message[:message]
          assert_equal level, message[:level]
        end

        it "sends #{level} exceptions" do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          request = nil
          @appender.client.stub(:bulk, -> r { request = r; {"status" => 201 } }) do
            @appender.send(level, 'Reading File', exc)
          end

          hash = request[:body][1]

          assert 'Reading File', hash[:message]
          assert exception = hash[:exception]
          assert 'NameError', exception[:name]
          assert 'undefined local variable or method', exception[:message]
          assert_equal level, hash[:level]
          assert exception[:stack_trace].first.include?(__FILE__), exception
        end

        it "sends #{level} custom attributes" do
          request = nil
          @appender.client.stub(:bulk, -> r { request = r; {"status" => 201 } }) do
            @appender.send(level, @message, {key1: 1, key2: 'a'})
          end

          message = request[:body][1]
          assert_equal @message, message[:message]
          assert_equal level, message[:level]
          refute message[:stack_trace]
          assert payload = message[:payload], message
          assert_equal 1, payload[:key1], message
          assert_equal 'a', payload[:key2], message
        end
      end

    end
  end
end
