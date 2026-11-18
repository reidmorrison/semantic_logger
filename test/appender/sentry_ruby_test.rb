require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Sentry
module Appender
  class SentryTest < Minitest::Test
    describe SemanticLogger::Appender::SentryRuby do
      let(:appender) { SemanticLogger::Appender::SentryRuby.new(level: :trace) }
      let(:amessage) { "AppenderRavenTest log message" }

      # Each appender registers an on_log subscriber, which closing it removes.
      after { appender.close }

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

      it "sends an exception whose #message raises" do
        error     = ExceptionFixtures::BrokenMessageError.new("Order 7")
        exception = scope = nil
        capture   = lambda { |exc, _h = {}|
          exception = exc
          scope     = ::Sentry.get_current_scope
        }
        ::Sentry.stub(:capture_exception, capture) { appender.error("Could not save", error) }

        assert_same error, exception
        assert_equal "Could not save", scope.extra[:message]
      end

      # Sentry serializes the event with JSON, which raises for such text with json 3.1, and warns
      # about it with json 2.8 to 3.0.x.
      it "sends binary text as UTF-8, keeping its characters" do
        error_message = scope = nil
        capture       = lambda { |msg, _h = {}|
          error_message = msg
          scope         = ::Sentry.get_current_scope
        }

        ::Sentry.stub(:capture_message, capture) do
          appender.error("Café ☕".b, body: "Café \xFF☕".b)
        end

        assert_equal "Café ☕", error_message
        assert_equal "Café ☕", scope.extra[:body]
        assert_equal Encoding::UTF_8, error_message.encoding
      end

      # Sentry's JSON.generate raises for a structure that holds itself, losing the event.
      it "sends a payload that holds itself, cut off where it repeats" do
        payload        = {name: "loop", body: "Café".b}
        payload[:self] = payload
        scope          = nil
        ::Sentry.stub(:capture_message, ->(*) { scope = ::Sentry.get_current_scope }) do
          appender.error("Looped", payload)
        end

        assert_equal "Café", scope.extra[:body]
        assert_equal "#<Hash nested too deeply>", scope.extra[:self][:self]
      end

      it "converts the text of a payload that also holds a structure nested too deeply" do
        nested = {leaf: 1}
        40.times { nested = {a: nested} }
        scope = nil
        ::Sentry.stub(:capture_message, ->(*) { scope = ::Sentry.get_current_scope }) do
          appender.error("Deep", body: "Café".b, tree: nested)
        end

        assert_equal "Café", scope.extra[:body]
        assert_includes scope.extra[:tree].inspect, "#<Hash nested too deeply>"
      end

      # Sentry writes such an object as it writes it; ActiveSupport's #as_json of an object whose
      # instance variables lead back to itself overflows the stack.
      it "sends a payload object as it is, without calling its #to_json" do
        broken = Object.new
        def broken.to_json(*) = raise(NoMethodError, "undefined method")
        scope = nil
        ::Sentry.stub(:capture_message, ->(*) { scope = ::Sentry.get_current_scope }) do
          appender.error("Failed", broken: broken, body: "Café".b)
        end

        assert_same broken, scope.extra[:broken]
        assert_equal "Café", scope.extra[:body]
      end

      describe "with the Sentry user or fingerprint in the payload" do
        allow_deprecation(/SentryRuby took the Sentry user or fingerprint from the log payload/)

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

        # As a HashWithIndifferentAccess finds a String key by its Symbol.
        it "takes the user from a payload whose Hash class finds its keys by Symbol" do
          indifferent = Class.new(Hash) do
            def [](key) = super(key.to_s)
            def delete(key) = super(key.to_s)
          end
          payload = indifferent.new.update("user_id" => 7, "amount" => 10)
          appender.instance_variable_set(:@payload_context_deprecated, true)

          scope = capture(error_log(payload))

          assert_equal({id: 7}, scope.user)
          assert_equal 10, scope.extra["amount"]
          assert_equal({"user_id" => 7, "amount" => 10}, payload)
        end

        it "takes the user and fingerprint from named tags whose Hash class finds their keys by Symbol" do
          indifferent = Class.new(Hash) do
            def [](key) = super(key.to_s)
            def delete(key) = super(key.to_s)
          end
          named_tags = indifferent.new.update("user_id" => 9, "fingerprint" => ["f"])

          scope = capture(error_log({}, named_tags))

          assert_equal({id: 9}, scope.user)
          assert_equal ["f"], scope.fingerprint
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

        it "takes each user field from the named tags over the payload" do
          scope = capture(error_log({user_id: 666, username: "eve"}, {user_id: 7}))

          assert_equal({id: 7, username: "eve"}, scope.user)
          assert_equal 666, scope.extra[:user_id]
        end

        it "merges a user Hash from the payload under the named tags" do
          payload = {user: {id: 666, "username" => "eve", segment: "paid"}}
          scope   = capture(error_log(payload, {user_id: 7, username: "bob"}))

          assert_equal({id: 7, username: "bob", segment: "paid"}, scope.user)
          refute scope.extra.key?(:user)
        end

        it "sends a user Hash from the payload with a value of another type as data" do
          scope = capture(error_log({user: {geo: {city: "Paris"}}}, {user_id: 7}))

          assert_equal({id: 7}, scope.user)
          assert_equal({geo: {city: "Paris"}}, scope.extra[:user])
        end

        it "takes a user field of any type from the named tags, and leaves out a nil one" do
          user_id = Object.new
          scope   = capture(error_log({}, {user_id: user_id, username: nil}))

          assert_equal({id: user_id}, scope.user)
          refute scope.tags.key?("username")
        end

        it "takes a fingerprint with numbers in it, as Strings" do
          scope = capture(error_log({fingerprint: ["upstream", 503, :timeout]}))

          assert_equal %w[upstream 503 timeout], scope.fingerprint
        end

        it "warns that taking a user Hash from the payload is deprecated" do
          assert_deprecated(/SemanticLogger: .*SentryRuby took the Sentry user or fingerprint from the log payload/) do
            capture(error_log({user: {segment: "paid"}}, {user_id: 7}))
          end
        end

        it "warns once that taking them from the payload is deprecated" do
          _result, warnings = deprecations_of do
            2.times { capture(error_log({user_id: 7})) }
          end

          assert_equal 1, warnings.size
          assert_match(/SentryRuby took the Sentry user or fingerprint from the log payload/, warnings.first)
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
                    assert_deprecated(/took the Sentry user or fingerprint from the log payload/) do
                      appender.error("some message", **args)
                    end
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

      describe "with the Sentry scope of the thread that logged the entry" do
        let(:appender) { SemanticLogger::Appender::SentryRuby.new }

        # Returns an entry logged on a thread of its own, after the block sets up that thread's
        # Sentry scope, as a request would.
        def log_on_thread(level = :error, named_tags: {})
          appender
          Thread.new do
            ::Sentry.with_scope do |scope|
              yield(scope) if block_given?
              log = SemanticLogger::Log.new("Checkout", level)
              log.assign(message: "Payment declined")
              log.named_tags = named_tags
              SemanticLogger::Logger.call_subscribers(log)
              log
            end
          end.value
        end

        def request_scope(scope)
          scope.set_user(id: 7, ip_address: "10.0.0.1")
          scope.set_tags(request: "r1")
          scope.set_contexts(order: {id: 42})
          scope.add_breadcrumb(::Sentry::Breadcrumb.new(message: "Loaded order"))
        end

        # Logs the entry directly on this thread, as the appender thread does, and returns the Sentry
        # scope it was captured with.
        def capture(log)
          scope = nil
          ::Sentry.stub(:capture_message, ->(*) { scope = ::Sentry.get_current_scope }) do
            appender.log(log)
          end
          scope
        end

        it "sends the user, tags, contexts, and breadcrumbs of that thread" do
          scope = capture(log_on_thread { |s| request_scope(s) })

          assert_equal({id: 7, ip_address: "10.0.0.1"}, scope.user)
          assert_equal "r1", scope.tags[:request]
          assert_equal({id: 42}, scope.contexts[:order])
          crumbs = scope.breadcrumbs.to_h[:values].map { |crumb| crumb[:message] }

          assert_equal ["Loaded order"], crumbs
        end

        it "adds the context from the named tags to it" do
          log   = log_on_thread(named_tags: {user_id: 9, region: "eu"}) { |s| request_scope(s) }
          scope = capture(log)

          assert_equal({id: 9, ip_address: "10.0.0.1"}, scope.user)
          assert_equal "eu", scope.tags["region"]
          assert_equal "r1", scope.tags[:request]
        end

        it "replaces a field of that thread's user keyed by a String" do
          log   = log_on_thread(named_tags: {user_id: 9}) { |s| s.set_user("id" => 7, "segment" => "paid") }
          scope = capture(log)

          assert_equal({id: 9, segment: "paid"}, scope.user)
        end

        it "runs the event processors of that thread's scope" do
          processor = ->(event, _hint) { event }
          scope     = capture(log_on_thread { |s| s.add_event_processor(&processor) })

          assert_includes scope.event_processors, processor
        end

        it "leaves the Rack env, with the request body, on that thread" do
          log = log_on_thread { |s| s.set_rack_env("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new("a=1")) }

          assert_empty log.captured(:sentry_scope).rack_env
          assert_empty capture(log).rack_env
        end

        it "does not run the appender's filter on that thread" do
          calls = 0
          appender.filter = ->(_log) { calls += 1 }
          log_on_thread

          assert_equal 0, calls
        end

        it "leaves the scope held by the log entry unchanged" do
          log = log_on_thread(named_tags: {region: "eu"}) { |s| request_scope(s) }
          capture(log)
          captured = log.captured(:sentry_scope)

          assert_equal({request: "r1"}, captured.tags)
          assert_empty captured.extra
        end

        it "does not capture the scope for an entry below the appender's level" do
          log = log_on_thread(:info) { |s| request_scope(s) }

          assert_nil log.captured(:sentry_scope)
        end

        it "stops capturing the scope once closed" do
          appender.close
          log = log_on_thread { |s| request_scope(s) }

          assert_nil log.captured(:sentry_scope)
        end
      end
    end
  end
end
