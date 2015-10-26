---
layout: default
---

### Write your own Custom Appender

To write your own appender it should meet the following requirements:

* Inherit from `SemanticLogger::Base`
* In the initializer connect to the resource being logged to
* Implement #log(log) which needs to write to the relevant resource
* Implement #flush if the resource can be flushed
* Write a test for the new appender

The #log method takes the `Log Struct` as a parameter.
For the format of the `Log Struct`, see [Log Struct](log_struct.html)

Basic outline for an Appender:

```ruby
require 'semantic_logger'

class SimpleAppender < SemanticLogger::Appender::Base
  def initialize(level=nil, &block)
    # Set the log level and formatter if supplied
    super(level, &block)
  end

  # Display the log struct and the text formatted output
  def log(log)
    # Ensure minimum log level is met, and check filter
    return false if (level_index > (log.level_index || 0)) || !include_message?(log)

    # Display the raw log structure
    p log

    # Display the formatted output
    puts formatter.call(log)
  end

  # Optional
  def flush
    puts "Flush :)"
  end
end
```

Sample program calling the above appender:

```ruby
SemanticLogger.default_level = :trace
# Log to file dev.log
SemanticLogger.add_appender('dev.log')
# Also log the above sample appender
SemanticLogger.add_appender(SimpleAppender.new)

logger = SemanticLogger['Hello']
logger.info "Hello World"
```

Look at the [existing appenders](https://github.com/reidmorrison/semantic_logger/tree/master/lib/semantic_logger/appender) for good examples

### Contribute

To have your custom appender included in the standard list of appenders, submit it along
with complete working tests.
See the [MongoDB Appender Test](https://github.com/reidmorrison/semantic_logger/blob/master/test/appender_mongodb_test.rb) for an example.

### [Next: Log Struct ==>](log_struct.html)
