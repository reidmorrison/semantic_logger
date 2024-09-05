---
layout: default
---

## Testing

New with Semantic Logger v4.13.

When writing tests we want to verify that the correct log messages, metrics, etc.
are being created by the application.
Since Semantic Logger uses a global logging mechanism we can't use the regular logging to
verify logging events.

### Minitest helpers

To add the Minitest helper methods, add the following line to `test_helper.rb`:

~~~ruby
Minitest::Test.include SemanticLogger::Test::Minitest
~~~

Example test file:

~~~ruby
require_relative "test_helper"

class UserTest < ActiveSupport::TestCase
  describe User do
    it "logs message" do
      messages = semantic_logger_events do
        # Captures all log events during this block
        User.new.enable!
      end

      # Confirm the number of expected messages
      assert_equal 2, messages.count, messages

      # Confirm that the first log message includes the following elements
      assert_semantic_logger_event(
        messages[0],
        level:   :info,
        message: "User enabled"
      )

      # Confirm that the second log message includes the following elements
      assert_semantic_logger_event(
        messages[1],
        level:   :debug,
        message: "Completed"
      )
    end
  end
end
~~~

For more examples on testing log messages,
see [Rails Semantic Logger tests](https://github.com/reidmorrison/rails_semantic_logger/blob/master/test/active_record_test.rb).

#### Capturing Events

The method `semantic_logger_events` returns all captured log events that occurred during the supplied block.

~~~ruby
messages = semantic_logger_events do
  # ... Captures all log events during this block
end
~~~

By default `semantic_logger_events` captures all log events. To narrow the events to only those
captured by a specific class, supply the class name. For Example:

~~~ruby
messages = semantic_logger_events(ApiClient) do
  # ... Only captures ApiClient log events created during this block.
end
~~~

#### Verifying a log event

Use `assert_semantic_logger_event` to verify that a single log event has all the required attributes.

~~~ruby
assert_semantic_logger_event(
  messages[0],
  level:   :info,
  message: "User enabled",
)
~~~

All arguments other than `event` are optional:

- `event`: `SemanticLogger::Log` the event captured.
- `message`: Text message to be logged.
- `message_includes`: A partial match of the message.
- `level`: Log level of the supplied log call: `:trace, :debug, :info, :warn, :error, :fatal`.
- `payload`: Exact match of hash of payload items.
- `payload_includes`: Partial match of payload items.
- `tags`: Any tags active on the thread when the log call was made.
- `named_tags`: Any tags active on the thread when the log call was made.
- `name`: Class name supplied to the logging instance.
- `exception`: Ruby Exception object that was logged.
- `metric`: The metric text supplied.
- `metric_amount`: Used for numeric or counter metrics.
- `dimensions`: Any dimensions captured.
- `context`: Hash of named contexts that were captured when the log entry was created.
- `time`: The time at which the log entry was created.
- `duration`: The time taken to complete a measure call in milli-seconds.
- `backtrace`: The backtrace captured if active.
- `thread_name`: Name of the thread in which the logging call was called.

Instead of asserting an exact match on the `message`, a partial match can be supplied using `message_includes`. For
example:

~~~ruby
assert_semantic_logger_event(
  messages[0],
  level:            :info,
  message_includes: "enabled"
)
~~~

To verify a partial payload, and ignore any extra keys in the payload, use `payload_includes` to
specify the partial payload.

Example, asserts the entire payload is an exact match:

~~~ruby
assert_semantic_logger_event(
  messages[0],
  level:   :info,
  message: "User enabled",
  payload: {
    first_name: "Jack",
    last_name:  "Jones"
  }
)
~~~

Example, asserts a partial payload matches:

~~~ruby
assert_semantic_logger_event(
  messages[0],
  level:            :info,
  message:          "User enabled",
  payload_includes: {
    first_name: "Jack"
  }
)
~~~

### RSpec

For RSpec users, this sample supplied by @jgascoignetaylor-godaddy will be useful:
~~~ruby
context 'when it blows up' do
  let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }

  it 'should should log the error' do
    allow_any_instance_of(MyThing).to receive(:logger).and_return(capture_logger)
    MyThing.new('asdf').do_something!

    expect(capture_logger.events.last.message).to include('Here is a message')
    expect(capture_logger.events.last.level).to eq(:error)
  end
end
~~~

Open to pull requests to implement the RSpec equivalent of the Minitest helpers: `SemanticLogger::Test::Minitest`.

### Other testing frameworks

If you use another testing framework and would like to contribute helper methods similar
to the ones supplied in Semantic Logger for Minitest, we would welcome a pull request.

The approach is to stub out the Semantic Logger and replace it with an instance of
`SemanticLogger::Test::CaptureLogEvents`. It looks and feels like a regular logging class,
except that it retains the log events in memory. The raw events are captured so that tests are not
affected by configured appenders or their formats.

Define a special test logger to capture log events:

~~~ruby
let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }
~~~

To capture just the log events from a specific class, stub the logger on that class:

~~~ruby
User.stub(:logger, logger) do
  # Capture all logging calls to the User logger.
end
~~~

Or, to capture all log events from all classes, stub the global logger:

~~~ruby
SemanticLogger::Logger.stub(:processor, logger) do
  # Capture all log events during the block.
end
~~~

The log events are now available in `logger.events`.

### [Next: Appenders ==>](appenders.html)
