---
layout: default
---

## Appenders

Appenders are destinations that log messages can be written to.

Log messages can be written to one or more of the following destinations at the same time:

* Text File
* $stderr or $stdout ( any IO stream )
* Syslog
* Graylog
* Elasticsearch
* Splunk
* logentries.com
* loggly.com
* Logstash
* Papertrail
* New Relic
* Bugsnag
* Signalfx
* Apache Kafka
* RabbitMQ (AMQP)
* HTTP(S)
* TCP (+ SSL)
* UDP
* MongoDB
* Rollbar
* Sentry
* Honeybadger
* Honeybadger Insights
* CloudWatch Logs
* Logger, log4r, etc.
* Grafana Loki

To ensure no log messages are lost it is recommend to use TCP over UDP for logging purposes.
Due to the architecture of Semantic Logger any performance difference between TCP and UDP will not
impact the performance of you application.

### Text File

Log to file with the standard formatter:

~~~ruby
SemanticLogger.add_appender(file_name: "development.log")
~~~

Log to file with the standard colorized formatter:

~~~ruby
SemanticLogger.add_appender(file_name: "development.log", formatter: :color)
~~~

Log to file in JSON format:

~~~ruby
SemanticLogger.add_appender(file_name: "development.log", formatter: :json)
~~~

For performance reasons the log file is not re-opened with every call.
When the log file needs to be rotated, use a copy-truncate operation rather
than deleting the file.

#### JSON log format

When writing json log output, it has the following layout:

~~~json
{
  "timestamp": "ISO-8601",
  
  "application": "Application name",
  "environment": "Custom Environment name",
  "host": "Host name",
  "pid": "Process Id",
  "thread": "Thread name or id",
  "file": "filename",
  "line": "line number",
  
  "level": "trace|debug|info|warn|error|fatal",
  "level_index": "0|1|2|3|4|5",
  "message": "The message text without any colorization",
  "name": "Name of the class that generated the log message. Including namespace, if any.",
  "tags": ["tag_name 1", "tag_name 2"],
  "duration": "Human readable duration",
  "duration_ms": "Duration in milliseconds",
  "metric": "Name of the metric",
  "metric_amount": "Size of the metric, usually 1",
  
  "named_tags": {
    "tag1": "any named tags will be inside this named_tags tag",
    "tag2": "any named tags will be inside this named_tags tag"
  },
  
  "payload": {
    "field1": "any custom payload fields will be inside this payload tag",
    "field2": "any custom payload fields will be inside this payload tag"
  },
  
  "exception": {
    "name": "Exception class name",
    "message": "Exception message",
    "stack_trace": ["line 1", "line 2"],
    "cause": {
      "name": "Exception class name",
      "message": "Exception message",
      "stack_trace": ["line 1", "line 2"]
    }
  }
}
~~~

Note: 
* The above JSON layout is formatted for readability. 
  The actual json layout will be a single line terminated with a single newline.
  It does not contain any embedded newlines.
* If a field has a nil value it is excluded from the output json.

### IO Streams

Semantic Logger can log data to any IO Stream instance, such as $stderr or $stdout

~~~ruby
# Log errors and above to standard error:
SemanticLogger.add_appender(io: $stderr, level: :error)
~~~

### Syslog

Log to a local Syslog daemon

~~~ruby
SemanticLogger.add_appender(appender: :syslog)
~~~

Log to a remote Syslog server using TCP with packet size 2048 bytes. By default the size is 1024 bytes:

~~~ruby
SemanticLogger.add_appender(
  appender: :syslog,
  url:      "tcp://myloghost:514",
  max_size: 2048
)
~~~

Log to a remote Syslog server using UDP:

~~~ruby
SemanticLogger.add_appender(
  appender: :syslog,
  url:      "udp://myloghost:514"
)
~~~

Optional: Add filter to exclude health_check, or other log entries:

~~~ruby
SemanticLogger.add_appender(
  appender: :syslog,
  url:      "udp://myloghost:514",
  filter:   Proc.new { |log| log.message !~ /(health_check|Not logged in)/ }
)
~~~

If logging to a remote Syslog server using UDP, add the following line to your `Gemfile`:

~~~ruby
gem "syslog_protocol"
~~~

If logging to a remote Syslog server using TCP, add the following lines to your `Gemfile`:

~~~ruby
gem "syslog_protocol"
gem "net_tcp_client"
~~~

Note: `:trace` level messages are mapped to `:debug`.

### Graylog

Send all log messages to a centralized logging server running [Graylog](https://www.graylog.org).

The Graylog appender retains all Semantic information when forwarding to Graylog.
( I.e. Data is sent as JSON and avoids the loss of semantic information which would gave occurred
had the log information been converted to text.)

For Rails applications, or running bundler, add the following line to the file `Gemfile`:

~~~ruby
gem "gelf"
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

To use the TCP Protocol:

~~~ruby
SemanticLogger.add_appender(
  appender: :graylog,
  url:      "tcp://localhost:12201"
)
~~~

Or, to use the UDP Protocol:

~~~ruby
SemanticLogger.add_appender(
  appender: :graylog,
  url:      "udp://localhost:12201"
)
~~~

If not using Rails, the `facility` can be removed, or set to a custom string describing the application.

Note: `:trace` level messages are mapped to `:debug`.

### Splunk HTTP

In order to write messages to the Splunk HTTP Collector, follow the Splunk instructions
to enable the [HTTP Event Collector](http://dev.splunk.com/view/event-collector/SP-CAAAE7F).
The instructions also include information on how to generate a token that needs to be supplied below.

~~~ruby
SemanticLogger.add_appender(
  appender: :splunk_http,
  url:      "http://localhost:8088/services/collector/event",
  token:    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
)
~~~

Once log messages have been sent, open the Splunk web interface and select Search.
To start with limit the message source to the newly added host:

If the machine's name generating the messages is `hostname`, Search for: `host=hostname`

Then change the output list to table view and select only these "interesting columns":

* host
* duration
* name
* level
* message

If HTTPS is being used for the Splunk HTTP Collector, update the url accordingly:

~~~ruby
SemanticLogger.add_appender(
  appender: :splunk_http,
  url:      "https://localhost:8088/services/collector/event",
  token:    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
)
~~~

#### Splunk HTTP Performance

In testing against a local Splunk instance the performance was only about 30 log messages per second.
For much better performance consider using the TCP appender to write to Splunk, it achieved 1,400 messages
per second with non-ssl. With SSL over TCP to Splunk it was logging just over 1,200 log messages per second.

### Elasticsearch

Forward all log messages to Elasticsearch.

Example:

~~~ruby
SemanticLogger.add_appender(
  appender:    :elasticsearch,
  url:         "http://localhost:9200",
  index:       "my-index",
  data_stream: true
)
~~~

### logentries.com

Follow the instructions on [logentries](https://logentries.com/doc/input-token/)
to obtain a token.

Replace `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` below with the above token.

~~~ruby
module Logentries
  class Formatter < SemanticLogger::Formatters::Json
    attr_accessor :token

    def initialize(token)
      @token = token
    end

    def call(log, logger)
      "#{token} #{super(log, logger)}"
    end
  end
end

formatter = Logentries::Formatter.new("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
SemanticLogger.add_appender(appender: :tcp, server: "api.logentries.com:20000", ssl: true, formatter: formatter)
~~~

### loggly.com

After signing up with Loggly obtain the token by logging into Loggly.com
Navigate to `Source Setup` -> `Customer Tokens` and copy the token

Replace `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` below with the above token.

~~~ruby
SemanticLogger.add_appender(
  appender: :http,
  url:      "http://logs-01.loggly.com/inputs/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/tag/semantic_logger/"
)
~~~

Once log messages have been sent, open the Loggly web interface and select Search.
To isolate the new messages start with the following search: `tag:"semantic_logger"`

In the Field Explorer change to Grid view and add the following fields using `Add as column to Grid`:

* host
* duration
* name
* level
* message

If HTTPS is being used for Loggly, update the url accordingly:

~~~ruby
SemanticLogger.add_appender(
  appender: :http,
  url:      "https://logs-01.loggly.com/inputs/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/tag/semantic_logger/"
)
~~~

### Logstash

Forward log messages to Logstash.

For Rails applications, or running bundler, add the following line to the file `Gemfile`:

~~~ruby
gem "logstash-logger"
~~~

Install gems:

~~~
bundle install
~~~

If not using Bundler:

~~~
gem install logstash-logger
~~~

If running Rails create an initializer with the following code, otherwise add the code
to your program:

~~~ruby
require "logstash-logger"

# Use the TCP logger
# See https://github.com/dwbutler/logstash-logger for further options
log_stash = LogStashLogger.new(type: :tcp, host: "localhost", port: 5229)

SemanticLogger.add_appender(logger: log_stash)
~~~

Note: `:trace` level messages are mapped to `:debug`.

### Papertrail

Papertrail accepts log messages via TLS TCP in syslog format.

Sample configuration:

~~~ruby
config.semantic_logger.add_appender(
    appender: :syslog,
    url:      "tcp://something.papertrailapp.com:1234",
    tcp_client: {
      ssl: {
        ca_file: File.join(Rails.root, "config", "papertrail-bundle.pem")
      }
    }
  )
~~~

For more information see the following section from [Papertrail's documentation](http://help.papertrailapp.com/kb/configuration/encrypting-remote-syslog-with-tls-ssl/). 

### Bugsnag

Forward `:info`, `:warn`, or `:error` log messages to Bugsnag.

Note: Payload information is not filtered, so take care not to push any sensitive
information when logging with tags or a payload.

Configure Bugsnag following the [Ruby Bugsnag documentation](https://bugsnag.com/docs/notifiers/ruby#sending-handled-exceptions).

To add to a Rails application that already uses [Rails Semantic Logger](rails.html)
create a file called `<Rails Root>/config/initializers/bugsnag.rb` with
the following contents and restart the application.

Send `:error` messages to Bugsnag:

~~~ruby
SemanticLogger.add_appender(appender: :bugsnag)
~~~

Or, for a standalone installation add the code above after initializing Semantic Logger.

Send `:warn` and `:error` messages to Bugsnag:

~~~ruby
SemanticLogger.add_appender(appender: :bugsnag, level: :warn)
~~~

Send `:info`, `:warn` and `:error` messages to Bugsnag:

~~~ruby
SemanticLogger.add_appender(appender: :bugsnag, level: :info)
~~~

### NewRelic

NewRelic supports Error Events in both it's paid and free subscriptions.

Adding the New Relic appender will by default send `:error` and `:fatal` log entries to
New Relic as error events.

Note: Payload information is not filtered, so take care not to push any sensitive
information when logging with tags or a payload.

For Rails applications, or running bundler, add the following line to the bottom of the file `Gemfile`:

~~~ruby
gem "newrelic_rpm"
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
SemanticLogger.add_appender(appender: :new_relic)
~~~

To also send warnings to NewRelic:

~~~ruby
SemanticLogger.add_appender(appender: :new_relic, level: :warn)
~~~

### MongoDB

Write log messages as documents into a MongoDB capped collection.

For Rails applications, or running bundler, add the following line to the file `Gemfile`:

~~~ruby
gem "mongo"
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
client   = Mongo::MongoClient.new("127.0.0.1", 27017)
database = client["test"]

appender = SemanticLogger::Appender::MongoDB.new(
  db:              database,
  collection_size: 1024**3, # 1.gigabyte
  application:     Rails.application.class.name
)
SemanticLogger.add_appender(appender: appender)
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

### Apache Kafka

Publish log messages to an Apache Kafka broker.

~~~ruby
SemanticLogger.add_appender(
  appender:     :kafka,
  seed_brokers: ["kafka1:9092", "kafka2:9092"],
)
~~~

### RabbitMQ (AMQP)

Stream log messages through a queue on RabbitMQ broker.

~~~ruby
SemanticLogger.add_appender(
  appender:      :rabbitmq,
  queue_name:    "semantic_logger",
  rabbitmq_host: "localhost",
  username:      "the-username",
  password:      "the-password",
)
~~~

### HTTP(S)

The HTTP appender supports sending JSON messages to most services that can accept log messages
in JSON format via HTTP or HTTPS.

~~~ruby
SemanticLogger.add_appender(
  appender: :http,
  url:      "http://localhost:8088/path"
)
~~~

To send messages via HTTPS, change the url to:

~~~ruby
SemanticLogger.add_appender(
  appender: :http,
  url:      "https://localhost:8088/path"
)
~~~

The JSON being sent can be modified as needed.

Example, customize the JSON being sent:

~~~ruby
formatter = Proc.new do |log, logger|
  h = log.to_h(logger.host, logger.application)

  # Change time from iso8601 to seconds since epoch
  h[:timestamp] = log.time.utc.to_f

  # Render to JSON
  h.to_json
end

SemanticLogger.add_appender(
  appender:  :http,
  url:       "https://localhost:8088/path",
  formatter: formatter
)
~~~

### TCP Appender (+SSL)

The TCP appender supports sending JSON or other formatted messages to services that can accept log messages
via TCP or TCP with SSL.

Send messages in JSON format over TCP:

~~~ruby
SemanticLogger.add_appender(
  appender: :tcp,
  server:   "localhost:8088"
)
~~~

Send messages in JSON format over TCP with SSL enabled:

~~~ruby
SemanticLogger.add_appender(
  appender: :tcp,
  server:   "localhost:8088",
  ssl:      true
)
~~~

When using self-signed certificates, or to disable verification of the server SSL certificate:

~~~ruby
SemanticLogger.add_appender(
  appender: :tcp,
  server:   "localhost:8088",
  ssl:      {verify_mode: OpenSSL::SSL::VERIFY_NONE}
)
~~~

Example, customize the message being sent:

~~~ruby
formatter = Proc.new do |log, logger|
  h = log.to_h(logger.host, logger.application)

  # Change time from iso8601 to seconds since epoch
  h[:timestamp] = log.time.utc.to_f

  # Render to JSON
  h.to_json
end

SemanticLogger.add_appender(
  appender: :tcp,
  server:   "localhost:8088",
  ssl:      {verify_mode: OpenSSL::SSL::VERIFY_NONE},
  formatter: formatter
)
~~~

See [Net::TCPClient](https://github.com/reidmorrison/net_tcp_client) for the remaining options that can be set when the appender is added.

### UDP Appender

The UDP appender supports sending JSON or other formatted messages to services that can accept log messages
via UDP.

Send messages in JSON format over UDP:

~~~ruby
SemanticLogger.add_appender(
  appender: :udp,
  server:   "localhost:8088"
)
~~~

Example, customize the message being sent:

~~~ruby
formatter = Proc.new do |log, logger|
  h = log.to_h(logger.host, logger.application)

  # Change time from iso8601 to seconds since epoch
  h[:timestamp] = log.time.utc.to_f

  # Render to JSON
  h.to_json
end

SemanticLogger.add_appender(
  appender:  :udp,
  server:    "localhost:8088",
  formatter: formatter
)
~~~

### Rollbar

In order to integrate Rollbar error handling into Semantic Logger it requires it's own 
current thread context. As such, it cannot use a regular appender unless running
in Synchronous logging mode.

As recommended by @gingerlime, to enable Rollbar for Semantic Logger add the following initializer:
~~~ruby
SemanticLogger.on_log do |log|
  next unless log.try(:level) == :error

  err = RuntimeError.new(log.try(:message))
  err.set_backtrace(log.backtrace) if log.backtrace
  Rollbar.error(err, :log_extra => log.to_h)
end
~~~

### Sentry

Usage of `sentry-raven` gem is possible but the gem itself is deprecated.

Use the `sentry-ruby` gem instead, and the corresponding appender:

~~~ruby
SemanticLogger.add_appender(appender: :sentry_ruby)
~~~

Some of the logging context will be sent to Sentry:

* From named tags, `transaction_name`.
  See <https://docs.sentry.io/platforms/ruby/enriching-events/transaction-name/>.
* From either named tags or payload, `user` is built based on `user_id`,
  `username`, `user_email`, `ip_address` keys plus any additional `user` key
  that happens to be a hash.
  See <https://docs.sentry.io/platforms/ruby/enriching-events/identify-user/>.
* From the payload, `fingerprint` can be used to configure grouping
  granularity. See <https://docs.sentry.io/platforms/ruby/usage/sdk-fingerprinting/>.
* Named tags are sent as tags. See <https://docs.sentry.io/platforms/ruby/enriching-events/tags/>
* The unnamed tags are sent in as the `:tag` tag, separated by commas. An existing
* Everything else from payload and context is added to the `extras`.

~~~ruby
SemanticLogger.tagged(transaction_name: "foo", user_id: 42, baz: "quz") do
  logger.error("some message", username: "joe", fingerprint: ["bar"])
end
~~~

### Honeybadger and Honeybadger Insights

Forward errors to Honeybadger.

~~~ruby
SemanticLogger.add_appender(appender: :honeybadger)
~~~

Forward all log messages to Honeybadger Insights as events.

~~~ruby
SemanticLogger.add_appender(appender: :honeybadger_insights)
~~~

Both appenders use the Honeybadger [gem configuration](https://docs.honeybadger.io/lib/ruby/gem-reference/configuration/).

### Grafana Loki

Sends log messages to [Grafana Loki](https://grafana.com/docs/loki) using its [HTTP push API](https://grafana.com/docs/loki/latest/reference/loki-http-api/#ingest-logs)

```ruby
SemanticLogger.add_appender(
  appender: :loki,
  url: "https://logs-prod-001.grafana.net",
  username: "grafana_username",
  password: "grafana_token_here",
  compress: true
)
```

Configure the URL, username and password according to your Grafana Loki instance. The `compress` option can be set to `true` to compress the log messages.

### CloudWatch Logs

Forward all log messages to CloudWatch Logs.

Example:

~~~ruby
SemanticLogger.add_appender(
  appender:    :cloudwatch_logs,
  client_kwargs: {region: "eu-west-1"},
  group: "/my/application",
  create_stream: true
)
~~~

### Logger, log4r, etc.

Semantic Logger can log to other logging libraries:

* Replace the existing log library to take advantage of the extensive Semantic Logger interface
while still writing to the existing destinations.
* Or, write to a destination not currently supported by Semantic Logger.

~~~ruby
ruby_logger = Logger.new($stdout)

# Log to an existing Ruby Logger instance
SemanticLogger.add_appender(logger: ruby_logger)
~~~

Note: `:trace` level messages are mapped to `:debug`.

### Multiple Appenders

Messages can be logged to multiple appenders at the same time.

Example, log to a local file and to a remote Syslog server such as syslog-ng over TCP:

~~~ruby
require "semantic_logger"
SemanticLogger.default_level = :trace
SemanticLogger.add_appender(file_name: "development.log", formatter: :color)
SemanticLogger.add_appender(appender: :syslog, url: "tcp://myloghost:514")
~~~

### Appender Logging Levels

The logging level for each appender can be set explicitly. This supports:

* Only write a sub-set of messages to a particular destination.
    * For example, level of `:error` will only send error messages to this appender
      when other appenders may also be writing `:info`, etc.

Stand alone example:

~~~ruby
require "semantic_logger"

# Set default log level for new logger instances
SemanticLogger.default_level = :info

# Log all warning messages and above to warnings.log
SemanticLogger.add_appender(file_name: "log/warnings.log", level: :warn)

# Log all trace messages and above to trace.log
SemanticLogger.add_appender(file_name: "log/trace.log", level: :trace)

logger = SemanticLogger["MyClass"]
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

Appenders can be created and logged to directly with the same API as for all other logging.
Supports logging specific activity in the current thread to a separate appender without it
being written to the appenders that have been registered in Semantic Logger.

Example:

~~~ruby
require "semantic_logger"

appender = SemanticLogger::Appender::File.new("separate.log", level: :info, formatter: :color)

# Use appender directly, without using global Semantic Logger
appender.warn "Only send this to separate.log"

appender.measure_info "Called supplier" do
  # Call supplier ...
end
~~~

Note: Once an appender has been registered with Semantic Logger it must not be called
      directly, otherwise non-deterministic concurrency issues will arise when it is used across threads.

### [Next: Metrics ==>](metrics.html)
