---
layout: default
---

## Appenders

### Logging to File

Log to file with the standard formatter:

```ruby
SemanticLogger.add_appender('development.log')
```

Log to file with the standard colorized formatter:

```ruby
SemanticLogger.add_appender('development.log', &SemanticLogger::Appender::Base.colorized_formatter)
```

For performance reasons the log file is not re-opened with every call.
When the log file needs to be rotated, use a copy-truncate operation rather
than deleting the file.

### Logging to an existing IO Stream

Semantic Logger can log data to any IO Stream instance, such as $stderr or $stdout

```ruby
# Log errors and above to standard error:
SemanticLogger.add_appender($stderror, :error)
```

### Logging to Syslog

```ruby
# Log to a local Syslog daemon
SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new)
```

```ruby
# Log to a remote Syslog server such as syslog-ng over TCP:
SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new(server: 'tcp://myloghost:514'))
```

### Logging to an existing Logger

During migration it is sometimes useful to make Semantic Logger log to an existing
logging framework. This makes the additional Semantic Logger API's available yet
can log to existing files or other appenders.

```ruby
ruby_logger = Logger.new(STDOUT)

# Log to an existing Ruby Logger instance
SemanticLogger.add_appender(ruby_logger)
```

The log level `:unknown` from the Ruby Logger is mapped to `:fatal` in Semantic Logger

The Semantic Logger log level `:trace` level calls are mapped to `:debug` in the
underlying standard Ruby Logger

### Logging to NewRelic

NewRelic supports Error Events in both it's paid and free subscriptions. This New Relic
Appender sends `:error` and `:fatal` level to New Relic as Error Events

Adding the New Relic appender will send `:error` and `:fatal` log entries to
New Relic as error events.

Note: Payload information is not filtered, so take care not to push any sensitive
information when logging with tags or a payload.

For a Rails application already configured to use Semantic Logger and New Relic,
create a file called `<Rails Root>/config/initializers/newrelic_appender.rb` with
the following contents and restart the application:

```ruby
# Send :error and :fatal log messages to New Relic as Error events
SemanticLogger.add_appender(SemanticLogger::Appender::NewRelic.new)
```

For a non-Rails application, send `:info` and more severe log entries to a file
called application.log and also send `:error` and `:fatal` to New Relic as Error events.

```ruby
# ./newrelic.yml needs to be set up
# See https://docs.newrelic.com/docs/ruby/ruby-agent-installation for more information.

require 'semantic_logger'
require 'newrelic_rpm'

# New Relic setup
NewRelic::Agent.manual_start

# SemanticLogger setup
SemanticLogger.default_level = :info
SemanticLogger.add_appender('application.log')
SemanticLogger.add_appender(SemanticLogger::Appender::NewRelic.new)
logger = SemanticLogger['Example']

# Log some messages
logger.info  'This is only written to application.log'
logger.error 'This is written to application.log and will also be sent to New Relic as an error event'

# The appender will send tags, payloads and benchmark duration to New Relic
logger.tagged('test') do
  logger.with_payload(key1: 123, key2: 'abc') do
    logger.benchmark_error('message') do
      sleep 0.001
    end
  end
end

# New Relic does not seem to receive any errors if the application exits too soon after sending error alerts.
sleep 10

# New Relic shutdown - should send any queued data before exiting
::NewRelic::Agent.shutdown
```

### Logging to Splunk

Send all `:error` and `:fatal` log entries to [Splunk](http://www.splunk.com) as text only messages.
All semantic information and exception traces will be converted to plain
text before being submitted to [Splunk](http://www.splunk.com).

Note: Payload information is not filtered, so take care not to push any sensitive
information when logging with tags or a payload.

For a Rails application already configured to use Semantic Logger and New Relic,
create a file called `<Rails Root>/config/initializers/splunk_appender.rb` with
the following contents and restart the application:

```ruby
# Send :error and :fatal log messages to Splunk
SemanticLogger.add_appender(SemanticLogger::Appender::Splunk.new)
```

### Logging to MongoDB

```ruby
require 'semantic_logger'
require 'mongo'

client   = Mongo::MongoClient.new
database = client['test']

mongodb_appender = SemanticLogger::Appender::MongoDB.new(
  db:              database,
  collection_size: 1024**3, # 1.gigabyte
  application:     'my_application'
)
SemanticLogger.add_appender(mongodb_appender)

logger = SemanticLogger['Example']

# Log some messages
logger.info 'This message is written to mongo as a document'
```

The following is written to Mongo:

```javascript
> db.semantic_logger.findOne()
{
	"_id" : ObjectId("53a8d5b99b9eb4f282000001"),
	"time" : ISODate("2014-06-24T01:34:49.489Z"),
	"host_name" : "appserver1",
	"pid" : null,
	"thread_name" : "2160245740",
	"name" : "Example",
	"level" : "info",
	"level_index" : 2,
	"application" : "my_application",
	"message" : "This message is written to mongo as a document"
}
```

### Logging to Multiple Appenders at the same time

Log to a local file and to a remote Syslog server such as syslog-ng over TCP:

```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
SemanticLogger.add_appender('development.log')
SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new(:server => 'tcp://myloghost:514'))
```

### Appender Logging Levels

It is sometimes useful to log a subset of the log messages to a separate file
or appender. For example, log `:error` and `:fatal` level messages to a special
error file.

Below is a stand-alone example that better shows this behavior:

```ruby
require 'semantic_logger'

# Set default log level for new logger instances
SemanticLogger.default_level = :info

# Log all warning messages and above to warnings.log
SemanticLogger.add_appender('log/warnings.log', :warn)

# Log all trace messages and above to trace.log
SemanticLogger.add_appender('log/trace.log', :trace)

logger = SemanticLogger['MyClass']
logger.level = :trace
logger.trace "This is a trace message"
logger.info "This is an info message"
logger.warn "This is a warning message"
```

The output is as follows:

```bash
==> trace.log <==
2013-08-02 14:15:56.733532 T [35669:70176909690580] MyClass -- This is a trace message
2013-08-02 14:15:56.734273 I [35669:70176909690580] MyClass -- This is an info message
2013-08-02 14:15:56.735273 W [35669:70176909690580] MyClass -- This is a warning message

==> warnings.log <==
2013-08-02 14:15:56.735273 W [35669:70176909690580] MyClass -- This is a warning message
```

### Using Appenders Standalone from Semantic Logger

Any appender can be used directly and all the regular Logging API's called
against it without needing to use the global Semantic Logger queuing and appender
thread. For example:

```ruby
require 'semantic_logger'

appender = SemanticLogger::Appender::File.new('separate.log', :info)

# Use appender directly, without using global Semantic Logger
appender.warn 'Only send this to separate.log'

appender.benchmark_info 'Called supplier' do
  # Call supplier ...
end
```

This technique can also be used to temporarily send certain log messages to a
separate file from the global logging.

Note: Do not call appenders directly that have been added to Semantic Logger.
Appender instances are not designed to be accessed concurrently by multiple threads.
A separate instance per thread is recommended in multi-threaded envrionments, or just
use the global Semantic Logger since it is specifically designed for concurrency.