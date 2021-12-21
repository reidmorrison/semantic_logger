require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Elasticsearch
module Appender
  class ElasticsearchTest < Minitest::Test
    describe SemanticLogger::Appender::Elasticsearch do
      describe "providing a url" do
        let :appender do
          if ENV["ELASTICSEARCH"]
            SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200")
          else
            Elasticsearch::Transport::Client.stub_any_instance(:bulk, true) do
              SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200")
            end
          end
        end

        let :log_message do
          "AppenderElasticsearchTest log message"
        end

        let :log do
          log         = SemanticLogger::Log.new("User", :info)
          log.message = log_message
          log
        end

        let :exception do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          exc
        end

        after do
          appender.close
        end

        it 'uses :timestamp as time_key' do
          assert_equal :timestamp, appender.formatter.time_key
        end

        describe "synchronous" do
          it "logs to daily indexes" do
            bulk_index = nil
            appender.stub(:write_to_elasticsearch, ->(messages) { bulk_index = messages.first }) do
              appender.info log_message
            end
            index = bulk_index["index"]["_index"]
            assert_equal "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}", index
          end

          it "logs message" do
            request = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
          end

          it "logs level" do
            request = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert_equal :info, hash[:level]
          end

          it "logs exception" do
            log.exception = exception
            request       = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert exception = hash[:exception]
            assert_equal "NameError", exception[:name]
            assert_match "undefined local variable or method", exception[:message]
            assert exception[:stack_trace].first.include?(__FILE__), exception
          end

          it "logs payload" do
            h           = {key1: 1, key2: "a"}
            log.payload = h
            request     = stub_client { appender.log(log) }

            assert_nil = request[:index]
            assert hash = request[:body][1]
            refute hash[:stack_trace]
            assert_equal h, hash[:payload], hash
          end
        end

        describe "async batch" do
          it "logs message" do
            request = stub_client { appender.batch([log]) }

            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
            assert_equal :info, hash[:level]
          end

          let :logs do
            Array.new(3) do |i|
              l         = log.dup
              l.message = "hello world#{i + 1}"
              l
            end
          end

          it "logs multiple messages" do
            request = stub_client { appender.batch(logs) }

            assert body = request[:body]
            assert_equal 6, body.size, body

            index = "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}"
            assert_equal index, body[0]["index"]["_index"]
            assert_equal "hello world1", body[1][:message]
            assert_equal index, body[2]["index"]["_index"]
            assert_equal "hello world2", body[3][:message]
            assert_equal index, body[4]["index"]["_index"]
            assert_equal "hello world3", body[5][:message]
          end
        end

        def stub_client(&block)
          request = nil
          appender.client.stub(:bulk, ->(r) { request = r; {"status" => 201} }, &block)
          request
        end
      end

      describe "logging to data-streams" do
        let :appender do
          if ENV["ELASTICSEARCH"]
            SemanticLogger::Appender::Elasticsearch.new(
              url: "http://localhost:9200",
              data_stream: true
            )
          else
            Elasticsearch::Transport::Client.stub_any_instance(:bulk, true) do
              SemanticLogger::Appender::Elasticsearch.new(
                url: "http://localhost:9200",
                data_stream: true
              )
            end
          end
        end

        let :log_message do
          "AppenderElasticsearchTest log message"
        end

        let :log do
          log         = SemanticLogger::Log.new("User", :info)
          log.message = log_message
          log
        end

        after do
          appender.close
        end

        it 'uses @timestamp as time_key' do
          assert_equal '@timestamp', appender.formatter.time_key
        end

        describe "synchronous" do
          it "logs to data-stream index without date" do
            request = stub_client { appender.log(log) }

            assert_equal 'semantic_logger', request[:index]
            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
          end
        end

        describe "async batch" do
          it "logs message" do
            request = stub_client { appender.batch([log]) }

            assert body = request[:body]

            assert_equal({}, body[0]["create"])
            assert hash = body[1]
            assert_equal log_message, hash[:message]
            assert_equal :info, hash[:level]
          end

          let :logs do
            Array.new(3) do |i|
              l         = log.dup
              l.message = "hello world#{i + 1}"
              l
            end
          end

          it "logs multiple messages" do
            request = stub_client { appender.batch(logs) }

            assert_equal 'semantic_logger', request[:index]
            assert body = request[:body]
            assert_equal 6, body.size, body

            assert_equal({}, body[0]["create"])
            assert_equal "hello world1", body[1][:message]
            assert_equal({}, body[2]["create"])
            assert_equal "hello world2", body[3][:message]
            assert_equal({}, body[4]["create"])
            assert_equal "hello world3", body[5][:message]
          end
        end

        def stub_client(&block)
          request = nil
          appender.client.stub(:bulk, ->(r) { request = r; {"status" => 201} }, &block)
          request
        end
      end

      describe "elasticsearch parameters" do
        let :appender do
          Elasticsearch::Transport::Client.stub_any_instance(:bulk, true) do
            SemanticLogger::Appender::Elasticsearch.new(
              hosts: [{host: "localhost", port: 9200}]
            )
          end
        end

        let :log_message do
          "AppenderElasticsearchTest log message"
        end

        let :log do
          log         = SemanticLogger::Log.new("User", :info)
          log.message = log_message
          log
        end

        let :exception do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          exc
        end

        after do
          appender.close
        end

        describe "synchronous" do
          it "logs to daily indexes" do
            bulk_index = nil
            appender.stub(:write_to_elasticsearch, ->(messages) { bulk_index = messages.first }) do
              appender.info log_message
            end
            index = bulk_index["index"]["_index"]
            assert_equal "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}", index
          end

          it "logs message" do
            request = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
          end

          it "logs level" do
            request = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert_equal :info, hash[:level]
          end

          it "logs exception" do
            log.exception = exception
            request       = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert exception = hash[:exception]
            assert_equal "NameError", exception[:name]
            assert_match "undefined local variable or method", exception[:message]
            assert exception[:stack_trace].first.include?(__FILE__), exception
          end

          it "logs payload" do
            h           = {key1: 1, key2: "a"}
            log.payload = h
            request     = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            refute hash[:stack_trace]
            assert_equal h, hash[:payload], hash
          end
        end

        describe "async batch" do
          it "logs message" do
            request = stub_client { appender.batch([log]) }

            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
            assert_equal :info, hash[:level]
          end

          let :logs do
            Array.new(3) do |i|
              l         = log.dup
              l.message = "hello world#{i + 1}"
              l
            end
          end

          it "logs multiple messages" do
            request = stub_client { appender.batch(logs) }

            assert body = request[:body]
            assert_equal 6, body.size, body

            index = "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}"
            assert_equal index, body[0]["index"]["_index"]
            assert_equal "hello world1", body[1][:message]
            assert_equal index, body[2]["index"]["_index"]
            assert_equal "hello world2", body[3][:message]
            assert_equal index, body[4]["index"]["_index"]
            assert_equal "hello world3", body[5][:message]
          end
        end

        def stub_client(&block)
          request = nil
          appender.client.stub(:bulk, ->(r) { request = r; {"status" => 201} }, &block)
          request
        end
      end
    end
  end
end
