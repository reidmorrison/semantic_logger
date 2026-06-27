---
layout: default
---

## Appenders
{:.no_toc}

**Contents**

* TOC
{:toc}

An **appender** is a destination that log entries are written to: a file, the screen, a database, or
a remote service. Semantic Logger can write to several appenders at the same time, each with its own
log level and format, all from the same log call. For example you might log colorized text to the
screen, JSON to a file, and errors to an external service simultaneously.

## Step 1: Add a destination

Every destination is added through one method, `SemanticLogger.add_appender`, usually once at startup.
The keyword you pass selects the kind of destination:

~~~ruby
# A text file
SemanticLogger.add_appender(file_name: "development.log")

# An IO stream, such as the screen
SemanticLogger.add_appender(io: $stdout)

# A built-in appender, selected by name
SemanticLogger.add_appender(appender: :elasticsearch, url: "http://localhost:9200")

# An existing Ruby or Rails logger
SemanticLogger.add_appender(logger: Logger.new($stdout))

# A metrics destination (see the Metrics guide)
SemanticLogger.add_appender(metric: :statsd, url: "udp://localhost:8125")
~~~

In a Rails app using [rails_semantic_logger](rails.html), put `add_appender` calls in an initializer
such as `config/initializers/semantic_logger.rb`. Otherwise add them wherever you configure Semantic
Logger when the application boots.

## Step 2: Set the level, format, and filter

In addition to its own settings, almost every appender accepts these common options, so each
destination can keep a different subset of the logs in a different format:

| Option | Description |
|--------|-------------|
| `level` | Only write entries at this level or higher to this appender. Defaults to `SemanticLogger.default_level`. |
| `formatter` | How to format the output, for example `:default`, `:color`, or `:json`. See [Custom formatters](config.html#custom-formatters). |
| `filter` | A `Regexp` or `Proc` selecting which entries this appender accepts. See [Filtering](config.html#filtering). |
| `application`, `environment`, `host` | Override the global values for this appender only. |

For example, write only warnings and above to a file, formatted as JSON:

~~~ruby
SemanticLogger.add_appender(file_name: "errors.log", level: :warn, formatter: :json)
~~~

## Step 3: Pick your destinations

The tables below list every built-in destination. Pick the ones you need and jump to their section
for a full example.

Appenders for third-party services need their backing gem (shown in the "Gem" column). Add it to your
`Gemfile` and run `bundle install`, or `gem install` it directly. The gem is loaded lazily the first
time the appender is used, and is never a hard dependency of Semantic Logger itself.

**Files and streams**

| Destination | `add_appender` argument | Gem |
|-------------|-------------------------|-----|
| [Text file](#text-file) | `file_name:` | |
| [IO stream](#io-streams) (`$stdout`, `$stderr`, ...) | `io:` | |
| [Another Ruby or Rails logger](#logger-log4r-etc) | `logger:` | |

**Network protocols**

| Destination | `add_appender` argument | Gem |
|-------------|-------------------------|-----|
| [HTTP(S)](#https) | `appender: :http` | |
| [TCP (+SSL)](#tcp-appender-ssl) | `appender: :tcp` | `net_tcp_client` |
| [UDP](#udp-appender) | `appender: :udp` | |
| [Syslog](#syslog) | `appender: :syslog` | `syslog_protocol`, `net_tcp_client` (remote) |

**Centralized logging and log aggregators**

| Destination | `add_appender` argument | Gem |
|-------------|-------------------------|-----|
| [Elasticsearch](#elasticsearch) | `appender: :elasticsearch` | `elasticsearch` |
| [OpenSearch](#opensearch) | `appender: :opensearch` | `opensearch-ruby` |
| [Graylog](#graylog) | `appender: :graylog` | `gelf` |
| [Splunk over HTTP](#splunk-http) | `appender: :splunk_http` | |
| [Splunk over TCP/SDK](#splunk-http) | `appender: :splunk` | `splunk-sdk-ruby` |
| [Grafana Loki](#grafana-loki) | `appender: :loki` | |
| [CloudWatch Logs](#cloudwatch-logs) | `appender: :cloudwatch_logs` | `aws-sdk-cloudwatchlogs` |
| [OpenTelemetry](#opentelemetry) | `appender: :open_telemetry` | `opentelemetry-logs-sdk` |
| [Logstash](#logstash) | `logger:` | `logstash-logger` |
| [logentries.com](#logentriescom) | `appender: :tcp` | `net_tcp_client` |
| [loggly.com](#logglycom) | `appender: :http` | |
| [Papertrail](#papertrail) | `appender: :syslog` | `syslog_protocol`, `net_tcp_client` |

**Error and exception monitoring**

| Destination | `add_appender` argument | Gem |
|-------------|-------------------------|-----|
| [Bugsnag](#bugsnag) | `appender: :bugsnag` | `bugsnag` |
| [Sentry](#sentry) | `appender: :sentry_ruby` | `sentry-ruby` |
| [Honeybadger](#honeybadger-and-honeybadger-insights) | `appender: :honeybadger` | `honeybadger` |
| [Honeybadger Insights](#honeybadger-and-honeybadger-insights) | `appender: :honeybadger_insights` | `honeybadger` |
| [New Relic](#newrelic) | `appender: :new_relic` | `newrelic_rpm` |
| [Rollbar](#rollbar) | via `SemanticLogger.on_log` | `rollbar` |

**Databases and message queues**

| Destination | `add_appender` argument | Gem |
|-------------|-------------------------|-----|
| [MongoDB](#mongodb) | `appender: :mongodb` | `mongo` |
| [Apache Kafka](#apache-kafka) | `appender: :kafka` | `ruby-kafka` |
| [RabbitMQ](#rabbitmq-amqp) | `appender: :rabbitmq` | `bunny` |

For metrics destinations such as Statsd, SignalFx, and New Relic, see [Metrics](metrics.html).

> **Tip:** To ensure no log messages are lost, prefer TCP over UDP. Because of Semantic Logger's
> asynchronous design, the performance difference between the two will not impact your application.

## Files and streams

### Text File

Log to a file, choosing a formatter to suit the reader:

~~~ruby
# Standard text:
SemanticLogger.add_appender(file_name: "development.log")

# Colorized text, for a terminal:
SemanticLogger.add_appender(file_name: "development.log", formatter: :color)

# JSON, for a machine:
SemanticLogger.add_appender(file_name: "development.log", formatter: :json)
~~~

For performance the log file is not re-opened on every call, so rotate it with a copy-truncate
operation rather than deleting the file. See [Log rotation](operations.html#log-rotation).

Log files frequently contain sensitive information. By default the file is created using the process
umask (the standard Ruby behavior). To restrict access, supply `permissions:`, applied both when the
file is created and to an existing log file:

~~~ruby
# Owner read/write, group read, no access for others:
SemanticLogger.add_appender(file_name: "production.log", permissions: 0o640)
~~~

### IO Streams

Log to any IO stream instance, such as `$stdout` or `$stderr`:

~~~ruby
# Log errors and above to standard error:
SemanticLogger.add_appender(io: $stderr, level: :error)
~~~

#### Splitting output across stdout and stderr

A common pattern routes lower severity entries to `$stdout` and warnings and errors to `$stderr`.
Semantic Logger allows one appender per console stream, so add one for each and use `level:` and/or
`filter:` to control what each writes:

~~~ruby
stdout_filter = ->(log) { %i[trace debug info].include?(log.level) }

# Informational messages to stdout:
SemanticLogger.add_appender(io: $stdout, formatter: :color, level: :trace, filter: stdout_filter)

# Warnings and above to stderr:
SemanticLogger.add_appender(io: $stderr, formatter: :color, level: :warn)
~~~

Adding a second appender for a console stream that already has one is ignored (to avoid duplicate
console output), but `$stdout` and `$stderr` are tracked separately.

### Logger, log4r, etc.

Semantic Logger can write to another logging library, either to gain the Semantic Logger interface
while still writing to an existing destination, or to reach a destination it does not support natively:

~~~ruby
ruby_logger = Logger.new($stdout)

# Log to an existing Ruby Logger instance
SemanticLogger.add_appender(logger: ruby_logger)
~~~

Note: `:trace` level messages are mapped to `:debug`.

## Structured output formats

The file, IO, and HTTP appenders can emit machine-readable output by choosing a structured
`formatter`. All three formats below produce a single line of JSON per entry.

### JSON

`formatter: :json` produces output with this layout:

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

Notes:

* The layout above is formatted for readability. The real output is a single line terminated by one
  newline, with no embedded newlines.
* A field with a `nil` value is excluded from the output.

### Fluentd

`formatter: :fluentd` is the same as `:json`, except it renames the log level fields to `severity` and
`severity_index` so they are recognized by the Kubernetes Fluentd log collector:

~~~ruby
SemanticLogger.add_appender(io: $stdout, formatter: :fluentd)
~~~

Differences from `:json`:

* `level` / `level_index` become `severity` / `severity_index`.
* `host` is excluded by default (under Fluentd it is usually the not-very-useful container id). Pass
  `log_host: true` to include it.
* The process fields `pid`, `thread`, `file`, and `line` are excluded by default. Pass
  `need_process_info: true` to include them.

Construct the formatter explicitly to override these defaults:

~~~ruby
formatter = SemanticLogger::Formatters::Fluentd.new(log_host: true, need_process_info: true)
SemanticLogger.add_appender(io: $stdout, formatter: formatter)
~~~

### ECS (Elastic Common Schema)

`formatter: :ecs` emits each entry using the nested field names of the
[Elastic Common Schema](https://www.elastic.co/docs/reference/ecs) (targeting ECS 8.x), so logs
integrate cleanly with Filebeat and the Elastic stack without an ingest pipeline to rename fields. The
typical deployment writes ECS JSON to stdout or a file and lets Filebeat or Elastic Agent ship it to
Elasticsearch:

~~~ruby
SemanticLogger.add_appender(io: $stdout, formatter: :ecs)
SemanticLogger.add_appender(file_name: "production.log", formatter: :ecs)
~~~

Semantic Logger fields map to ECS as follows:

| Semantic Logger | ECS |
| :--- | :--- |
| `time` | `@timestamp` |
| `level` | `log.level` |
| `name` | `log.logger` |
| `file` / `line` | `log.origin.file.name` / `log.origin.file.line` |
| `message` | `message` |
| `thread` | `process.thread.name` |
| `pid` | `process.pid` |
| `host` | `host.hostname` |
| `application` | `service.name` |
| `environment` | `service.environment` |
| `exception` | `error.type` / `error.message` / `error.stack_trace` |
| `duration` | `event.duration` (nanoseconds) |
| `tags` | `tags` |
| `named_tags` | `labels.*` |
| `payload`, `metric`, `metric_amount` | nested under a custom namespace (see below) |

ECS reserves the top-level field names it defines, so Semantic Logger data with no native ECS home
(`payload`, `metric`, and `metric_amount`) is nested under a custom top-level namespace,
`semantic_logger` by default. A proper-noun namespace is
[the approach ECS recommends](https://www.elastic.co/docs/reference/ecs/ecs-custom-fields-in-ecs) for
custom fields, since it never collides with a current or future ECS field. Rename it with
`namespace:`:

~~~ruby
formatter = SemanticLogger::Formatters::Ecs.new(namespace: "my_app")
SemanticLogger.add_appender(io: $stdout, formatter: formatter)
~~~

Or set `namespace: nil` to merge the payload directly into ECS `labels` alongside the named tags:

~~~ruby
formatter = SemanticLogger::Formatters::Ecs.new(namespace: nil)
SemanticLogger.add_appender(io: $stdout, formatter: formatter)
~~~

## Network protocols

### HTTP(S)

The HTTP appender sends JSON to most services that accept log messages over HTTP or HTTPS:

~~~ruby
SemanticLogger.add_appender(appender: :http, url: "http://localhost:8088/path")

# For HTTPS, just change the scheme:
SemanticLogger.add_appender(appender: :http, url: "https://localhost:8088/path")
~~~

The JSON being sent can be customized with a formatter:

~~~ruby
formatter = Proc.new do |log, logger|
  h = log.to_h(logger.host, logger.application)

  # Change time from iso8601 to seconds since epoch
  h[:timestamp] = log.time.utc.to_f

  # Render to JSON
  h.to_json
end

SemanticLogger.add_appender(appender: :http, url: "https://localhost:8088/path", formatter: formatter)
~~~

#### Batching

By default each entry is sent in its own HTTP request. To send multiple entries in one request as a
JSON array, enable batching with `batch: true`. This suits endpoints that accept an array and create
one document per element, such as the
[Filebeat http_endpoint input](https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-http_endpoint.html):

~~~ruby
SemanticLogger.add_appender(appender: :http, url: "http://localhost:8088/path", batch: true)
~~~

With batching the appender runs on its own thread and flushes once `batch_size` entries have
accumulated (default 300) or `batch_seconds` have elapsed (default 5), whichever comes first:

~~~ruby
SemanticLogger.add_appender(
  appender:      :http,
  url:           "http://localhost:8088/path",
  batch:         true,
  batch_size:    100,
  batch_seconds: 10
)
~~~

### TCP Appender (+SSL)

The TCP appender sends JSON or other formatted messages to services that accept log messages over TCP,
optionally with SSL:

~~~ruby
# Plain TCP:
SemanticLogger.add_appender(appender: :tcp, server: "localhost:8088")

# TCP with SSL:
SemanticLogger.add_appender(appender: :tcp, server: "localhost:8088", ssl: true)

# With self-signed certificates, or to disable server certificate verification:
SemanticLogger.add_appender(
  appender: :tcp,
  server:   "localhost:8088",
  ssl:      {verify_mode: OpenSSL::SSL::VERIFY_NONE}
)
~~~

Customize the message with a formatter:

~~~ruby
formatter = Proc.new do |log, logger|
  h = log.to_h(logger.host, logger.application)
  h[:timestamp] = log.time.utc.to_f # seconds since epoch
  h.to_json
end

SemanticLogger.add_appender(appender: :tcp, server: "localhost:8088", formatter: formatter)
~~~

See [Net::TCPClient](https://github.com/reidmorrison/net_tcp_client) for the remaining connection
options.

The TCP and UDP appenders separate records with a newline, so they default to the JSON formatter,
which escapes embedded newlines and is safe with untrusted data. If you switch to a text formatter
such as `:default` or `:color`, enable `escape_control_chars` so a newline in the data cannot forge or
split a record:

~~~ruby
SemanticLogger.add_appender(
  appender:  :tcp,
  server:    "localhost:8088",
  formatter: {default: {escape_control_chars: true}}
)
~~~

### UDP Appender

The UDP appender sends JSON or other formatted messages over UDP:

~~~ruby
SemanticLogger.add_appender(appender: :udp, server: "localhost:8088")
~~~

Customize the message with a formatter:

~~~ruby
formatter = Proc.new do |log, logger|
  h = log.to_h(logger.host, logger.application)
  h[:timestamp] = log.time.utc.to_f # seconds since epoch
  h.to_json
end

SemanticLogger.add_appender(appender: :udp, server: "localhost:8088", formatter: formatter)
~~~

### Syslog

Log to a local Syslog daemon:

~~~ruby
SemanticLogger.add_appender(appender: :syslog)
~~~

Log to a remote Syslog server over TCP (the `net_tcp_client` and `syslog_protocol` gems are required).
The default packet size is 1024 bytes:

~~~ruby
SemanticLogger.add_appender(appender: :syslog, url: "tcp://myloghost:514", max_size: 2048)
~~~

Or over UDP (the `syslog_protocol` gem is required):

~~~ruby
SemanticLogger.add_appender(appender: :syslog, url: "udp://myloghost:514")
~~~

Add a filter to exclude noisy entries such as health checks:

~~~ruby
SemanticLogger.add_appender(
  appender: :syslog,
  url:      "udp://myloghost:514",
  filter:   Proc.new { |log| log.message !~ /(health_check|Not logged in)/ }
)
~~~

Syslog frames each record, so embedded newlines or other control characters in untrusted data could
forge or split records. The syslog formatters therefore escape control characters by default. To pass
them through unchanged:

~~~ruby
SemanticLogger.add_appender(
  appender:  :syslog,
  url:       "tcp://myloghost:514",
  formatter: {syslog: {escape_control_chars: false}}
)
~~~

Note: `:trace` level messages are mapped to `:debug`.

## Centralized logging and aggregators

### Elasticsearch

Forward all log entries to Elasticsearch (requires the `elasticsearch` gem). By default entries are
written to a daily index named `semantic_logger-YYYY.MM.DD`; override it with `index:`:

~~~ruby
SemanticLogger.add_appender(
  appender:    :elasticsearch,
  url:         "http://localhost:9200",
  index:       "my-index",
  data_stream: true
)
~~~

For an end-to-end walkthrough with Kibana, see [Centralized Logging](operations.html#centralized-logging).

### OpenSearch

Forward all log entries to OpenSearch, for example AWS OpenSearch (requires the `opensearch-ruby`
gem). OpenSearch is a fork of Elasticsearch and uses the same bulk indexing API, so this appender
accepts the same options as [Elasticsearch](#elasticsearch). Use it instead of the Elasticsearch
appender when talking to an OpenSearch server, since recent `elasticsearch` gems reject
non-Elasticsearch servers with an `Elasticsearch::UnsupportedProductError`:

~~~ruby
SemanticLogger.add_appender(
  appender:    :opensearch,
  url:         "http://localhost:9200",
  index:       "my-index",
  data_stream: true
)
~~~

### Graylog

Send log entries to a [Graylog](https://www.graylog.org) server (requires the `gelf` gem). Data is
sent as JSON, so all of the semantic structure is retained rather than being flattened into text.

Over TCP:

~~~ruby
SemanticLogger.add_appender(appender: :graylog, url: "tcp://localhost:12201")
~~~

Or over UDP:

~~~ruby
SemanticLogger.add_appender(appender: :graylog, url: "udp://localhost:12201")
~~~

If not using Rails, the `facility` can be removed, or set to a custom string describing the
application. Note: `:trace` level messages are mapped to `:debug`.

### Splunk HTTP

To write to the Splunk HTTP Collector, follow the Splunk instructions to enable the
[HTTP Event Collector](http://dev.splunk.com/view/event-collector/SP-CAAAE7F) and generate a token:

~~~ruby
SemanticLogger.add_appender(
  appender: :splunk_http,
  url:      "http://localhost:8088/services/collector/event",
  token:    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
)
~~~

For HTTPS, change the URL scheme to `https`. Once entries have been sent, open the Splunk web
interface, select Search, limit to the new host (`host=hostname`), switch to table view, and select
the interesting columns: `host`, `duration`, `name`, `level`, `message`.

**Performance:** against a local Splunk instance, the HTTP collector handled only about 30 entries per
second. For much higher throughput, write to Splunk with the [TCP appender](#tcp-appender-ssl)
instead, which reached about 1,400 entries per second (1,200 with SSL).

### Grafana Loki

Send log entries to [Grafana Loki](https://grafana.com/docs/loki) via its
[HTTP push API](https://grafana.com/docs/loki/latest/reference/loki-http-api/#ingest-logs):

~~~ruby
SemanticLogger.add_appender(
  appender: :loki,
  url:      "https://logs-prod-001.grafana.net",
  username: "grafana_username",
  password: "grafana_token_here",
  compress: true
)
~~~

Set the URL, username, and password to match your Loki instance. Set `compress: true` to compress the
log messages.

### CloudWatch Logs

Forward all log entries to AWS CloudWatch Logs (requires the `aws-sdk-cloudwatchlogs` gem):

~~~ruby
SemanticLogger.add_appender(
  appender:      :cloudwatch_logs,
  client_kwargs: {region: "eu-west-1"},
  group:         "/my/application",
  create_stream: true
)
~~~

### OpenTelemetry

Send log entries to [OpenTelemetry](https://opentelemetry.io) through its
[Logs API](https://opentelemetry.io/docs/specs/otel/logs/), so they can be exported to any
OpenTelemetry-compatible backend (the OTLP collector, Honeycomb, Datadog, Grafana, and so on).

This appender requires the `opentelemetry-logs-sdk` gem plus an exporter such as
`opentelemetry-exporter-otlp-logs`:

~~~ruby
gem "opentelemetry-logs-sdk"
gem "opentelemetry-exporter-otlp-logs"
~~~

Configure the OpenTelemetry SDK once at startup, then add the appender. `OpenTelemetry::SDK.configure`
reads the standard `OTEL_*` environment variables (for example `OTEL_EXPORTER_OTLP_ENDPOINT`) and
installs a logger provider, which the appender picks up automatically:

~~~ruby
require "opentelemetry-logs-sdk"
require "opentelemetry-exporter-otlp-logs"

OpenTelemetry::SDK.configure

SemanticLogger.add_appender(appender: :open_telemetry)
~~~

Each entry is emitted with its level mapped to the matching OpenTelemetry severity number, the message
as the record body, and the payload as record attributes. The appender registers a
`SemanticLogger.on_log` subscriber that captures the current OpenTelemetry context as each entry is
logged, so log records are correlated with the active trace and span.

| Option | Description |
|--------|-------------|
| `name` | Instrumentation scope name reported to OpenTelemetry. Defaults to `"SemanticLogger"`. |
| `version` | Instrumentation scope version. Defaults to the Semantic Logger gem version. |
| `metrics` | Whether to forward metric-only log entries. Defaults to `true`. |

### Logstash

Forward log entries to Logstash through the `logstash-logger` gem. Configure a `LogStashLogger` and
hand it to Semantic Logger as a `logger:` appender:

~~~ruby
require "logstash-logger"

# See https://github.com/dwbutler/logstash-logger for further options
log_stash = LogStashLogger.new(type: :tcp, host: "localhost", port: 5229)

SemanticLogger.add_appender(logger: log_stash)
~~~

Note: `:trace` level messages are mapped to `:debug`.

### logentries.com

Obtain a token by following the [logentries instructions](https://logentries.com/doc/input-token/),
then prefix each JSON line with the token using a small custom formatter over the TCP appender:

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

After signing up with Loggly, obtain a token under `Source Setup` -> `Customer Tokens`, then post to
the Loggly input URL with the HTTP appender:

~~~ruby
SemanticLogger.add_appender(
  appender: :http,
  url:      "https://logs-01.loggly.com/inputs/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/tag/semantic_logger/"
)
~~~

Once entries have been sent, open the Loggly web interface, select Search, and start with
`tag:"semantic_logger"`. In the Field Explorer switch to Grid view and add the columns `host`,
`duration`, `name`, `level`, and `message`.

### Papertrail

Papertrail accepts log entries over TLS TCP in syslog format:

~~~ruby
config.semantic_logger.add_appender(
  appender:   :syslog,
  url:        "tcp://something.papertrailapp.com:1234",
  tcp_client: {
    ssl: {
      ca_file: File.join(Rails.root, "config", "papertrail-bundle.pem")
    }
  }
)
~~~

See [Papertrail's documentation](http://help.papertrailapp.com/kb/configuration/encrypting-remote-syslog-with-tls-ssl/)
for more.

## Error and exception monitoring

> **Note:** These appenders forward the payload as supplied. Take care not to push sensitive
> information in tags or a payload.

### Bugsnag

Forward `:info`, `:warn`, or `:error` entries to Bugsnag (requires the `bugsnag` gem). Configure
Bugsnag following the
[Ruby Bugsnag documentation](https://bugsnag.com/docs/notifiers/ruby#sending-handled-exceptions), then
add the appender, choosing the minimum level to forward:

~~~ruby
# :error and above (the default)
SemanticLogger.add_appender(appender: :bugsnag)

# :warn and above
SemanticLogger.add_appender(appender: :bugsnag, level: :warn)

# :info and above
SemanticLogger.add_appender(appender: :bugsnag, level: :info)
~~~

### Sentry

Use the `sentry-ruby` gem and the corresponding appender (the older `sentry-raven` gem works but is
deprecated):

~~~ruby
SemanticLogger.add_appender(appender: :sentry_ruby)
~~~

Some logging context is forwarded to Sentry:

* From named tags, `transaction_name`. See
  <https://docs.sentry.io/platforms/ruby/enriching-events/transaction-name/>.
* From named tags or payload, `user` is built from the `user_id`, `username`, `user_email`, and
  `ip_address` keys, plus any `user` key that is itself a hash. See
  <https://docs.sentry.io/platforms/ruby/enriching-events/identify-user/>.
* From the payload, `fingerprint` configures grouping granularity. See
  <https://docs.sentry.io/platforms/ruby/usage/sdk-fingerprinting/>.
* Named tags are sent as Sentry tags. See
  <https://docs.sentry.io/platforms/ruby/enriching-events/tags/>.
* Unnamed tags are sent as the `:tag` tag, separated by commas.
* Everything else from the payload and context is added to `extras`.

~~~ruby
SemanticLogger.tagged(transaction_name: "foo", user_id: 42, baz: "quz") do
  logger.error("some message", username: "joe", fingerprint: ["bar"])
end
~~~

### Honeybadger and Honeybadger Insights

Forward errors to Honeybadger (requires the `honeybadger` gem):

~~~ruby
SemanticLogger.add_appender(appender: :honeybadger)
~~~

Or forward all log entries to Honeybadger Insights as events:

~~~ruby
SemanticLogger.add_appender(appender: :honeybadger_insights)
~~~

Both appenders use the Honeybadger
[gem configuration](https://docs.honeybadger.io/lib/ruby/gem-reference/configuration/).

### NewRelic

New Relic supports Error Events on both its paid and free plans. The appender sends `:error` and
`:fatal` entries to New Relic as error events by default (requires the `newrelic_rpm` gem):

~~~ruby
SemanticLogger.add_appender(appender: :new_relic)

# To also send warnings:
SemanticLogger.add_appender(appender: :new_relic, level: :warn)
~~~

### Rollbar

Rollbar needs its own current-thread context, so it cannot run as a regular appender unless logging is
[synchronous](operations.html#synchronous-operation). Integrate it with an `on_log` subscriber instead
(as recommended by @gingerlime):

~~~ruby
SemanticLogger.on_log do |log|
  next unless log.try(:level) == :error

  err = RuntimeError.new(log.try(:message))
  err.set_backtrace(log.backtrace) if log.backtrace
  Rollbar.error(err, :log_extra => log.to_h)
end
~~~

## Databases and message queues

### MongoDB

Write log entries as documents into a MongoDB capped collection (requires the `mongo` gem):

~~~ruby
appender = SemanticLogger::Appender::MongoDB.new(
  uri:             "mongodb://127.0.0.1:27017/test",
  collection_size: 1024**3, # 1 gigabyte
  application:     Rails.application.class.name
)
SemanticLogger.add_appender(appender: appender)
~~~

Each entry is stored as a document:

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

Publish log entries to an Apache Kafka broker (requires the `ruby-kafka` gem):

~~~ruby
SemanticLogger.add_appender(
  appender:     :kafka,
  seed_brokers: ["kafka1:9092", "kafka2:9092"]
)
~~~

### RabbitMQ (AMQP)

Stream log entries through a queue on a RabbitMQ broker (requires the `bunny` gem):

~~~ruby
SemanticLogger.add_appender(
  appender:      :rabbitmq,
  queue_name:    "semantic_logger",
  rabbitmq_host: "localhost",
  username:      "the-username",
  password:      "the-password"
)
~~~

## Logging to several destinations at once

Add as many appenders as you like; every entry is written to all of them. Use a per-appender `level`
so each destination keeps a different subset.

~~~ruby
require "semantic_logger"

SemanticLogger.default_level = :info

# Everything at :warn and above to one file:
SemanticLogger.add_appender(file_name: "log/warnings.log", level: :warn)

# Everything at :trace and above to another:
SemanticLogger.add_appender(file_name: "log/trace.log", level: :trace)

logger = SemanticLogger["MyClass"]
logger.level = :trace
logger.trace "This is a trace message"
logger.info  "This is an info message"
logger.warn  "This is a warning message"
~~~

Each file receives only the entries at or above its level:

~~~
==> trace.log <==
2013-08-02 14:15:56.733532 T [35669:70176909690580] MyClass -- This is a trace message
2013-08-02 14:15:56.734273 I [35669:70176909690580] MyClass -- This is an info message
2013-08-02 14:15:56.735273 W [35669:70176909690580] MyClass -- This is a warning message

==> warnings.log <==
2013-08-02 14:15:56.735273 W [35669:70176909690580] MyClass -- This is a warning message
~~~

A common combination is colorized text to a local file plus a remote aggregator:

~~~ruby
SemanticLogger.add_appender(file_name: "development.log", formatter: :color)
SemanticLogger.add_appender(appender: :syslog, url: "tcp://myloghost:514")
~~~

## Standalone appenders

An appender can be created and logged to directly, using the same API as any logger. This is useful to
send specific activity on the current thread to a separate destination, without writing it to the
appenders registered with Semantic Logger:

~~~ruby
require "semantic_logger"

appender = SemanticLogger::Appender::File.new("separate.log", level: :info, formatter: :color)

appender.warn "Only send this to separate.log"

appender.measure_info "Called supplier" do
  # Call supplier ...
end
~~~

Note: once an appender has been registered with Semantic Logger, do not also call it directly.
Non-deterministic concurrency issues arise when it is used across threads.
