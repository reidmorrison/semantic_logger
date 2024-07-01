require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Sentry
module Appender
  class SentryTest < Minitest::Test
    describe SemanticLogger::Appender::SentryRuby do
      let(:appender) { SemanticLogger::Appender::SentryRuby.new(level: :trace) }
      let(:amessage) { "AppenderRavenTest log message" }

      SemanticLogger::LEVELS.each do |level|
        it "sends #{level} message" do
          error_message = hash = scope = nil

          capture = lambda { |msg, h = {}|
            error_message = msg
            hash = h
            scope = ::Sentry.get_current_scope
          }

          ::Sentry.stub(:capture_message, capture) do
            appender.send(level, amessage)
          end

          assert_equal amessage, error_message
          assert_equal "SemanticLogger::Appender::SentryRuby", scope.extra[:name]
          assert hash.key?(:backtrace)
          assert_equal level, scope.level
        end

        it "sends #{level} exceptions" do
          error     = RuntimeError.new("Oh no, Error.")
          exception = hash = scope = nil

          capture = lambda { |exc, h = {}|
            exception = exc
            hash = h
            scope = ::Sentry.get_current_scope
          }

          ::Sentry.stub(:capture_exception, capture) do
            appender.send(level, amessage, error)
          end

          assert_equal error.class.to_s, exception.class.to_s
          assert_equal error.message, exception.message
          assert_equal amessage, scope.extra[:message]
          assert_equal level, scope.level
        end
      end

      describe "when enriching events" do
        let(:capture) do
          lambda { |msg, payload = {}|
            @argument = msg
            @payload = payload
            @scope = ::Sentry.get_current_scope
          }
        end

        it "uses the tags and arguments" do
          appender
          Sentry.with_scope do |scope|
            # sentry-only tag
            scope.set_tags("some" => "tag")

            SemanticLogger.tagged(tag: "tag 1") do
              SemanticLogger.tagged("tag 2") do
                SemanticLogger.tagged(transaction_name: "foo", user_id: 42, baz: "quz") do
                  ::Sentry.stub(:capture_message, capture) do
                    args = {username: "joe", fingerprint: ["bar"], other: "unrelated"}
                    appender.error("some message", **args)
                  end
                end
              end
            end
          end

          assert_equal :error, @scope.level
          assert_equal "some message", @scope.extra[:message]
          assert_equal ["bar"], @scope.fingerprint
          assert_equal "foo", @scope.transaction_name
          assert_equal "unrelated", @scope.extra[:other]

          expected_tags = { "tag" => "tag 1, tag 2", "baz" => "quz", "some" => "tag" }
          assert_equal expected_tags, @scope.tags

          expected_user_data = { id: 42, username: "joe" }
          assert_equal expected_user_data, @scope.user
        end
      end
    end
  end
end
