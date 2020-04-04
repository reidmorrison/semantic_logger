require_relative "../test_helper"
require_relative "fake_bunny"

module Appender
  class RabbitmqTest < Minitest::Test
    describe SemanticLogger::Appender::Rabbitmq do
      after do
        @appender&.close
      end

      it "sends log messages in JSON format" do
        bunny = nil
        Bunny.stub(:new, ->(*args) { bunny = FakeBunny.new(args) }) do
          @appender = SemanticLogger::Appender::Rabbitmq.new(
            queue_name:    "test_queue",
            rabbitmq_host: "localhost",
            username:      "the-username",
            password:      "the-password"
          )

          bunny_args = bunny.args.first
          assert_equal "localhost", bunny_args[:host]
          assert_equal "the-username", bunny_args[:username]
          assert_equal "the-password", bunny_args[:password]

          message = "AppenderRabbitmqTest log message"
          @appender.info(message)
          @appender.flush

          assert_equal "test_queue", bunny.published.first[:queue]
          h = JSON.parse(bunny.published.first[:message])
          assert_equal "info", h["level"]
          assert_equal message, h["message"]
          assert_equal "SemanticLogger::Appender::Rabbitmq", h["name"]
          assert_equal $$, h["pid"]
        end
      end
    end
  end
end
