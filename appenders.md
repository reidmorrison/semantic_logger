---
layout: default
---

### Appenders

Appenders are destinations that log messages can be written to. Several appenders can be active
at the same time, so that for example log messages can be written to all of the following destinations at once:

* Text File
* $stderr or $stdout ( any IO stream )
* Syslog
* Graylog
* Splunk
* New Relic
* Bug Snag
* MongoDB

### Text File

Log to file with the standard formatter:

~~~ruby
SemanticLogger.add_appender('development.log')
~~~

Log to file with the standard colorized formatter:

~~~ruby
SemanticLogger.add_appender('development.log', &SemanticLogger::Appender::Base.colorized_formatter)
~~~

For performance reasons the log file is not re-opened with every call.
When the log file needs to be rotated, use a copy-truncate operation rather
than deleting the file.

### IO Streams

Semantic Logger can log data to any IO Stream instance, such as $stderr or $stdout

~~~ruby
# Log errors and above to standard error:
SemanticLogger.add_appender($stderror, :error)
~~~

### Syslog or SyslogNG

~~~ruby
# Log to a local Syslog daemon
SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new)
~~~

~~~ruby
# Log to a remote Syslog server such as syslog-ng over TCP:
SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new(server: 'tcp://myloghost:514'))
~~~

Note: `:trace` level messages are mapped to `:debug`.

### Graylog

Send all log messages to a centralized logging server running [Graylog](https://www.graylog.org).

The Graylog appender retains all Semantic information when forwarding to Graylog.
( I.e. Data is sent as JSON and avoids the loss of semantic information which would gave occurred
had the log information been converted to text.)

For Rails applications, or running bundler, add the following line to the file `Gemfile`:

~~~ruby
gem 'gelf'
~~~

Install gems:

~~~
bundle install
~~~

If not using Bundler:

~~~
gem install gelf
~~~

To add to a Rails application that already uses [Rails Semantic Logger](rails.html)
create a file called `<Rails Root>/config/initializers/graylog.rb` with
the following contents and restart the application.

To use the UDP Protocol:

~~~ruby
unless Rails.env.test? || Rails.env.development?
  appender        = SemanticLogger::Appender::Graylog.new(
    server:   'localhost',
    port:     12201,
    facility: Rails.application.class.name
  )
  # Optional: Add filter to exclude health_check, or other log entries
  appender.filter = Proc.new { |log| log.message !~ /(health_check|Not logged in)/ }

  SemanticLogger.add_appender(appender)
  SemanticLogger.backtrace_level = SemanticLogger.default_level
end
~~~
Or, to use the TCP Protocol:

~~~ruby
unless Rails.env.test? || Rails.env.development?
  appender        = SemanticLogger::Appender::Graylog.new(
    server:   'localhost',
    port:     12201,
    protocol: :tcp,
    facility: Rails.application.class.name
  )
  # Optional: Add filter to exclude health_check, or other log entries
  appender.filter = Proc.new { |log| log.message !~ /(health_check|Not logged in)/ }

  SemanticLogger.add_appender(appender)
  SemanticLogger.backtrace_level = SemanticLogger.default_level
end
~~~

If not using Rails, the `facility` can be removed, or set to a custom string describing the application.

Note: `:trace` level messages are mapped to `:debug`.

### Splunk

Send all `:error` and `:fatal` log entries to [Splunk](http://www.splunk.com) as text only messages.
All semantic information and exception traces will be converted to plain
text before being submitted to [Splunk](http://www.splunk.com).

Note: Payload information is not filtered, so take care not to push any sensitive
information when logging with tags or a payload.

For Rails applications, or running bundler, add the following line to the file `Gemfile`:

~~~ruby
gem 'splunk-sdk-ruby'
~~~

Install gems:

~~~
bundle install
~~~

If not using Bundler:

~~~
gem install splunk-sdk-ruby
~~~

To add to a Rails application that already uses [Rails Semantic Logger](rails.html)
create a file called `<Rails Root>/config/initializers/splunk.rb` with
the following contents and restart the application.

~~~ruby
unless Rails.env.test? || Rails.env.development?
  appender = SemanticLogger::Appender::Splunk.new(
    host:     'localhost',
    port:     8089,
    username: 'username',
    password: 'password',
    index:    'main'
  )
  SemanticLogger.add_appender(appender)
end
~~~

Note: `:trace` level messages are mapped to `:debug`.

### NewRelic

NewRelic supports Error Events in both it's paid and free subscriptions.

Adding the New Relic appender will by default send `:error` and `:fatal` log entries to
New Relic as error events.

Note: Payload information is not filtered, so take care not to push any sensitive
information when logging with tags or a payload.

For Rails applications, or running bundler, add the following line to the bottom of the file `Gemfile`:

~~~ruby
gem 'newrelic_rpm'
~~~

Install gems:

~~~
bundle install
~~~

If not using Bundler:

~~~
gem install newrelic_rpm
~~~

To add to a Rails application that already uses [Rails Semantic Logger](rails.html)
create a file called `<Rails Root>/config/initializers/new_relic.rb` with
the following contents and restart the application.

~~~ruby
unless Rails.env.test? || Rails.env.development?
  SemanticLogger.add_appender(SemanticLogger::Appender::NewRelic.new)
end
~~~

Note: `:trace` level messages are mapped to `:debug`.

### MongoDB

Write log messages as documents into a MongoDB capped collection.

For Rails applications, or running bundler, add the following line to the file `Gemfile`:

~~~ruby
gem 'mongo'
~~~

Install gems:

~~~
bundle install
~~~

If not using Bundler:

~~~
gem install mongo
~~~

To add to a Rails application that already uses [Rails Semantic Logger](rails.html)
create a file called `<Rails Root>/config/initializers/mongodb.rb` with
the following contents and restart the application.

~~~ruby
unless Rails.env.test? || Rails.env.development?
  client   = Mongo::MongoClient.new('localhost', 27017)
  database = client['test']

  appender = SemanticLogger::Appender::MongoDB.new(
    db:              database,
    collection_size: 1024**3, # 1.gigabyte
    application:     Rails.application.class.name
  )
  SemanticLogger.add_appender(appender)
end
~~~

The following is written to Mongo:

~~~javascript
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
~~~

### Logger, log4r, etc.

Semantic Logger can log to other logging libraries:

* Replace the existing log library to take advantage of the extensive Semantic Logger interface
while still writing to the existing destinations.
* Or, write to a destination not currently supported by Semantic Logger.

~~~ruby
ruby_logger = Logger.new(STDOUT)

# Log to an existing Ruby Logger instance
SemanticLogger.add_appender(ruby_logger)
~~~

Note: `:trace` level messages are mapped to `:debug`.

### Multiple Appenders

Messages can be logged to multiple appenders at the same time.

Example, log to a local file and to a remote Syslog server such as syslog-ng over TCP:

~~~ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
SemanticLogger.add_appender('development.log')
SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new(:server => 'tcp://myloghost:514'))
~~~

### Appender Logging Levels

The logging level for each appender can be set explicitly. This supports:

* Only write a sub-set of messages to a particular destination.
    * For example, level of `:error` will only send error messages to this appender
      when other appenders may also be writing `:info`, etc.

Stand alone example:

~~~ruby
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
~~~

The output is as follows:

~~~bash
==> trace.log <==
2013-08-02 14:15:56.733532 T [35669:70176909690580] MyClass -- This is a trace message
2013-08-02 14:15:56.734273 I [35669:70176909690580] MyClass -- This is an info message
2013-08-02 14:15:56.735273 W [35669:70176909690580] MyClass -- This is a warning message

==> warnings.log <==
2013-08-02 14:15:56.735273 W [35669:70176909690580] MyClass -- This is a warning message
~~~

### Standalone

Appenders can be created at logged to directly with the same API as for all other logging.
Supports logging specific activity in the current thread to a separate appender without it
being written to the appenders that have been registered in Semantic Logger.

Example:

~~~ruby
require 'semantic_logger'

appender = SemanticLogger::Appender::File.new('separate.log', :info)

# Use appender directly, without using global Semantic Logger
appender.warn 'Only send this to separate.log'

appender.benchmark_info 'Called supplier' do
  # Call supplier ...
end
~~~

Note: Once an appender has been registered with Semantic Logger it must not be called
      directly, otherwise non-deterministic concurrency issues will arise when it is used across threads.

### [Next: Signals ==>](signals.html)
