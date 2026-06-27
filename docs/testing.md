---
layout: default
---

## Testing
{:.no_toc}

**Contents**

* TOC
{:toc}

When testing application code, you often want to assert that it logged the right thing: the expected
message, level, payload, or metric. Semantic Logger logs through a global, asynchronous pipeline, so
you cannot simply read it back from a normal appender. Instead it ships a test helper that **captures
log events in memory** during a block, so you can make assertions on them.

The events are captured as raw `SemanticLogger::Log` objects, before any appender or formatter runs,
so your assertions are not affected by how logging happens to be configured.

The fastest path is the Minitest helpers below. RSpec and other frameworks are covered further down.

## Minitest

### Step 1: install the helpers

Add the helper methods to your tests, once, in `test_helper.rb`:

~~~ruby
Minitest::Test.include SemanticLogger::Test::Minitest
~~~

### Step 2: capture events

Wrap the code under test in `semantic_logger_events`. It returns every log event created during the
block:

~~~ruby
messages = semantic_logger_events do
  User.new.enable!
end
~~~

By default it captures events from every class. To capture only the events from one class, pass that
class:

~~~ruby
messages = semantic_logger_events(ApiClient) do
  # Only ApiClient log events created during this block are captured.
end
~~~

### Step 3: assert on the events

Check how many events were produced, then assert on each one with `assert_semantic_logger_event`:

~~~ruby
require_relative "test_helper"

class UserTest < ActiveSupport::TestCase
  describe User do
    it "logs message" do
      messages = semantic_logger_events do
        User.new.enable!
      end

      # How many events were logged
      assert_equal 2, messages.count, messages

      # The first event
      assert_semantic_logger_event(
        messages[0],
        level:   :info,
        message: "User enabled"
      )

      # The second event
      assert_semantic_logger_event(
        messages[1],
        level:   :debug,
        message: "Completed"
      )
    end
  end
end
~~~

Every argument other than the event itself is optional, so you assert only on what matters to the
test. The available checks are:

| Argument | Checks |
|----------|--------|
| `message` | Exact match of the text message. |
| `message_includes` | Partial (substring) match of the message. |
| `level` | Log level: `:trace`, `:debug`, `:info`, `:warn`, `:error`, `:fatal`. |
| `payload` | Exact match of the payload Hash. |
| `payload_includes` | Partial match: the given keys/values, ignoring any others. |
| `tags` | Tags active on the thread when logged. |
| `named_tags` | Named tags active on the thread when logged. |
| `name` | Class name of the logger. |
| `exception` | The Ruby exception that was logged. |
| `metric` | The metric name. |
| `metric_amount` | The metric amount. |
| `dimensions` | The metric dimensions. |
| `context` | Named contexts captured with the entry. |
| `time` | When the entry was created. |
| `duration` | Duration of a measure call, in milliseconds. |
| `backtrace` | The captured backtrace, if any. |
| `thread_name` | Name of the thread that logged the entry. |

### Match part of a message or payload

For assertions that should not break on incidental detail, match partially.

Use `message_includes` for a substring of the message:

~~~ruby
assert_semantic_logger_event(
  messages[0],
  level:            :info,
  message_includes: "enabled"
)
~~~

Use `payload_includes` to assert specific payload keys while ignoring any extras. Compare with
`payload`, which must match the whole Hash exactly:

~~~ruby
# Exact: the payload must be exactly these keys and values
assert_semantic_logger_event(
  messages[0],
  level:   :info,
  message: "User enabled",
  payload: {first_name: "Jack", last_name: "Jones"}
)

# Partial: first_name must be present, other keys are ignored
assert_semantic_logger_event(
  messages[0],
  level:            :info,
  message:          "User enabled",
  payload_includes: {first_name: "Jack"}
)
~~~

For more examples, see the
[Rails Semantic Logger tests](https://github.com/reidmorrison/rails_semantic_logger/blob/master/test/active_record_test.rb).

## RSpec

There is no RSpec port of the Minitest helpers yet (pull requests welcome). In the meantime, capture
events with `SemanticLogger::Test::CaptureLogEvents` and stub it in as the logger:

~~~ruby
context "when it blows up" do
  let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }

  it "logs the error" do
    allow_any_instance_of(MyThing).to receive(:logger).and_return(capture_logger)
    MyThing.new("asdf").do_something!

    expect(capture_logger.events.last.message).to include("Here is a message")
    expect(capture_logger.events.last.level).to eq(:error)
  end
end
~~~

(Sample courtesy of @jgascoignetaylor-godaddy.)

## Other test frameworks

The same approach works anywhere: replace the logger with a
`SemanticLogger::Test::CaptureLogEvents` instance. It looks and behaves like a normal logger, but
keeps the raw log events in memory instead of writing them, so your assertions are unaffected by the
configured appenders or their formats.

~~~ruby
logger = SemanticLogger::Test::CaptureLogEvents.new
~~~

Stub it onto a single class to capture just that class's logging:

~~~ruby
User.stub(:logger, logger) do
  # Capture all logging calls to the User logger.
end
~~~

Or stub the global processor to capture logging from every class:

~~~ruby
SemanticLogger::Logger.stub(:processor, logger) do
  # Capture all log events during the block.
end
~~~

Either way, the captured events are available as `logger.events`.

If you add helper methods for another framework like the Minitest ones, a pull request would be
welcome.
