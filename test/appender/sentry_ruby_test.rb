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

      describe "with the Sentry user or fingerprint in the payload" do
        # Logs the entry directly, and returns the Sentry scope it was captured with.
        def capture(log)
          scope = nil
          ::Sentry.stub(:capture_message, ->(*) { scope = ::Sentry.get_current_scope }) do
            appender.log(log)
          end
          scope
        end

        def error_log(payload, named_tags = {})
          log = SemanticLogger::Log.new("Webhook", :error)
          log.assign(message: "Webhook rejected", payload: payload)
          log.named_tags = named_tags
          log
        end

        it "leaves the log entry and the application's payload unchanged" do
          attributes = {user_id: 7, fingerprint: ["a"], amount: 10}
          log        = error_log(attributes, {transaction_name: "checkout", username: "bob"})
          scope      = capture(log)

          assert_equal({id: 7, username: "bob"}, scope.user)
          assert_equal ["a"], scope.fingerprint
          assert_equal({user_id: 7, fingerprint: ["a"], amount: 10}, attributes)
          assert_equal({user_id: 7, fingerprint: ["a"], amount: 10}, log.payload)
          assert_equal({transaction_name: "checkout", username: "bob"}, log.named_tags)
        end

        it "sends a value of the wrong type as data, instead of raising" do
          scope = capture(error_log({fingerprint: "not an array", user_id: {id: 1}, user: "not a hash"}))

          assert_empty scope.fingerprint
          assert_empty scope.user
          assert_equal "not an array", scope.extra[:fingerprint]
          assert_equal({id: 1}, scope.extra[:user_id])
        end

        it "sends a payload that is not a Hash as data, instead of raising" do
          scope = capture(error_log([1, 2]))

          assert_equal [1, 2], scope.extra[:payload]
        end

        it "takes the fingerprint from the named tags, without sending it as a tag" do
          scope = capture(error_log({}, {fingerprint: ["grouped"]}))

          assert_equal ["grouped"], scope.fingerprint
          refute scope.tags.key?("fingerprint")
        end

        it "warns once that taking them from the payload is deprecated" do
          original             = Warning[:deprecated]
          Warning[:deprecated] = true
          _out, err            = capture_io do
            2.times { capture(error_log({user_id: 7})) }
          end

          assert_equal 1, err.scan("SentryRuby took the Sentry user or fingerprint from the log payload").size
        ensure
          Warning[:deprecated] = original
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

          expected_tags = {"tag" => "tag 1, tag 2", "baz" => "quz", "some" => "tag"}

          assert_equal expected_tags, @scope.tags

          expected_user_data = {id: 42, username: "joe"}

          assert_equal expected_user_data, @scope.user
        end
      end
    end
  end
end
