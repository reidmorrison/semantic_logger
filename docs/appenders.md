---
layout: default
title: Appenders
description: >-
  Every destination Semantic Logger writes to and how to configure it: files
  and streams, structured formats, network protocols, log aggregators, and
  error monitors.
---


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

Pass one of these keywords to each call, and call `add_appender` once for each destination, see
[Logging to several destinations at once](#logging-to-several-destinations-at-once). Given more than
one, it adds only the first of `file_name:`, `io:`, `logger:`, `appender:`, and `metric:`, and
reports a [deprecation warning](upgrading.html#seeing-deprecation-warnings); v6 raises an
`ArgumentError`.

In a Rails app using [rails_semantic_logger](rails.html), put `add_appender` calls in an initializer
such as `config/initializers/semantic_logger.rb`. Otherwise add them wherever you configure Semantic
Logger when the application boots.

## Step 2: Set the level, format, and filter

In addition to its own settings, almost every appender accepts these common options, so each
destination can keep a different subset of the logs in a different format:

| Option | Description |
|--------|-------------|
| `level` | Only write entries at this level or higher to this appender. Defaults to `SemanticLogger.default_level`. |
| `formatter` | How to format the output, for example `:default`, `:color`, or `:json`. A [block given to `add_appender`](config.html#formatter-as-a-block-or-proc) takes its place. See [Custom formatters](config.html#custom-formatters). |
| `filter` | A `Regexp` or `Proc` selecting which entries this appender accepts. See [Filtering](config.html#filtering). |
| `application`, `environment`, `host` | Override the global values for this appender only. |
| `metrics` | Whether to also write metric-only entries, which have a metric but no message and no exception. Defaults to `false`, except for `:kafka`, `:rabbitmq`, and `:udp`, which default to `true` until v6, and warn when it is not supplied. See [Metrics in log appenders](metrics.html#metrics-in-log-appenders). |

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
| [Syslog](#syslog) | `appender: :syslog` | `syslog` (local, Ruby 3.4+), `syslog_protocol` (remote), `net_tcp_client` (TCP) |

**Centralized logging and log aggregators**

| Destination | `add_appender` argument | Gem |
|-------------|-------------------------|-----|
| [Elasticsearch](#elasticsearch) | `appender: :elasticsearch` | `elasticsearch` |
| [OpenSearch](#opensearch) | `appender: :opensearch` | `opensearch-ruby` |
| [Graylog](#graylog) | `appender: :graylog` | `gelf` |
| [Splunk over HTTP](#splunk-http) | `appender: :splunk_http` | |
| [Splunk SDK](#splunk-sdk) (deprecated) | `appender: :splunk` | `splunk-sdk-ruby` |
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

The file is opened when the appender is added, so a bad path or insufficient permissions raise
immediately from `add_appender` instead of failing later on the logging thread.

For performance the log file is not re-opened on every call, so rotate it with a copy-truncate
operation rather than deleting the file. See [Log rotation](operations.html#log-rotation).

Log files frequently contain sensitive information. By default the file is created using the process
umask (the standard Ruby behavior). To restrict access, supply `permissions:`, applied both when the
file is created and to an existing log file:

~~~ruby
# Owner read/write, group read, no access for others:
SemanticLogger.add_appender(file_name: "production.log", permissions: 0o640)
~~~

With `permissions:`, the log file must be a regular file owned by the process, with a single hard
link, that the file name names directly rather than through a symbolic link. Nothing is written to
any other file, such as a log file linked to `/dev/stdout`, nor when the file cannot be opened:
`add_appender` raises `IOError` giving the reason, and a file that fails the check when it is
reopened later, for example on a rotation, is reported and not written to until it is fixed. To log
to standard output, use `io: $stdout` instead. See
[Log file permissions](security.html#log-file-permissions).

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
`formatter`. Each format below produces a single line per entry.

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
  "method": "Method that logged it, such as Order#submit",

  "level": "trace|debug|info|warn|error|fatal",
  "level_index": "0|1|2|3|4|5",
  "message": "The message text without any colorization",
  "name": "Name of the class that generated the log message. Including namespace, if any.",
  "tags": ["tag_name 1", "tag_name 2"],
  "duration": "Human readable duration",
  "duration_ms": "Duration in milliseconds",
  "metric": "Name of the metric",
  "metric_amount": "Size of the metric, usually 1",
  "dimensions": {"region": "The metric's dimensions, when it has any"},

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
* To also log the detail Ruby adds to an exception's message, such as did_you_mean suggestions, as
  `exception.details`, enable `log_exception_details`: `formatter: {json: {log_exception_details: true}}`.
  See [Exception details](config.html#exception-details).

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
* The process fields `pid`, `thread`, `file`, `line`, and `method` are excluded by default. Pass
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
| `method` | `log.origin.function` |
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
| `payload`, `metric`, `metric_amount`, `dimensions` | nested under a custom namespace (see below) |

ECS reserves the top-level field names it defines, so Semantic Logger data with no native ECS home
(`payload`, `metric`, `metric_amount`, and `dimensions`) is nested under a custom top-level namespace,
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

### Logfmt

`formatter: :logfmt` emits each entry as a single line of `key=value` pairs in
[logfmt](https://brandur.org/logfmt) format, common with Heroku and Grafana Loki tooling:

~~~ruby
SemanticLogger.add_appender(io: $stdout, formatter: :logfmt)
~~~

~~~
timestamp="2024-07-20T08:32:05.375276Z" level="info" name="MyClass" message="Hello World" tag="success"
~~~

Notes:

* The timestamp is ISO 8601, under the key `timestamp` unless the formatter's `time_key` is set
  (`formatter: {logfmt: {time_key: :ts}}`). All values are quoted and escaped, so a newline in the
  data cannot forge or split a record.
* Keys (from tags, named tags, and the payload) cannot be quoted in logfmt, so spaces, control
  characters (including the Unicode line and paragraph separators), invisible format characters
  (such as a zero width space), `=`, and `"` in a key are replaced with `_`, and invalid UTF-8 is
  dropped. For example the tag `second breakfast` is emitted as `second_breakfast=true`.
* Named tags and payload fields are merged into the top-level `key=value` pairs. A key named like
  one of the entry's own fields (the time key, `level`, `name`, `message`, `duration`,
  `duration_ms`, `tag`, or an exception field) is emitted with its source as a prefix, so that
  logged data cannot replace those fields: `payload.level="fatal"`, `named_tags.message="..."`, or
  `tags.message=true`. A key that starts with `tags.`, `named_tags.`, or `payload.` is prefixed
  too, as in `payload.named_tags.level`, so that it cannot pass for another source's field.
* Other keys that are the same once encoded, including keys that only differ by type (such as
  `:user` and `"user"`), are emitted once, with the value from the later source: the payload wins
  over named tags, and named tags over tags.
* Unnamed tags are emitted as keys with a `true` value.
* A nested value, such as a Hash or an Array in the payload, is emitted as its JSON text, quoted:
  `user="{\"id\":7}"`.
* `tag="success"` is emitted on every entry, becoming `tag="exception"` when the entry carries an
  exception, which is then included as the fields `exception_name`, `exception_message`,
  `stack_trace`, and, when the exception has a cause, `cause`. With `log_exception_details: true`
  (off by default), the detail Ruby adds to the exception's message is included as
  `exception_details`; see [Exception details](config.html#exception-details).

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

#### Query parameters

Some log servers are configured through the query string of the ingestion url rather than through
headers or the body. A query string on `url:` is kept and sent with every request that submits log
data, for example when pointing at
[VictoriaLogs](https://docs.victoriametrics.com/victorialogs/data-ingestion/):

~~~ruby
SemanticLogger.add_appender(
  appender: :http,
  url:      "http://localhost:9428/insert/jsonline?_msg_field=message&_time_field=timestamp"
)
~~~

The query is applied after the request path, so it also works for the appenders built on top of the
HTTP appender (`:elasticsearch_http`, `:splunk_http`, `:loki`, and the `:signalfx` metrics appender),
each of which appends its own path to the url:

~~~ruby
SemanticLogger.add_appender(
  appender: :elasticsearch_http,
  url:      "http://localhost:9428/insert/elasticsearch?_msg_field=message&_time_field=timestamp"
)
~~~

#### Batching

By default each entry is sent in its own HTTP request. To send multiple entries in one request as a
JSON array, enable batching with `batch: true`. This suits endpoints that accept an array and create
one document per element, such as the
[Filebeat http_endpoint input](https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-http_endpoint.html):

~~~ruby
SemanticLogger.add_appender(appender: :http, url: "http://localhost:8088/path", batch: true)
~~~

The formatter formats the whole batch with its `#batch(logs, logger)`, as the default `:json`
formatter does. `add_appender` raises an `ArgumentError` for a formatter that cannot, such as a
[formatter block](config.html#formatter-as-a-block-or-proc), given with `batch: true`.

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

#### When the server does not accept a request

An entry is written once the server answers its request with a 2xx status. The HTTP appender, and
those built on it (`:elasticsearch_http`, `:splunk_http`, `:loki`, and the `:signalfx` metrics
appender), handle any other answer by its status:

* A 4xx other than 408 and 429, such as `400 Bad Request` or `401 Unauthorized`, rejects the request
  itself, so sending it again cannot succeed. With `async: true` or `batch: true`, its entries are
  discarded straight away. When the server rejects a batch, which is sent in one request, for the
  entries it holds, with `400 Bad Request`, `413 Content Too Large`, or `422 Unprocessable Content`,
  the batch is first split up and sent again in parts, so that only the entries in the parts the
  server rejects are discarded. Any other such 4xx, such as `401 Unauthorized`, `403 Forbidden`, or
  `404 Not Found`, rejects the request whatever it holds, so the whole batch is discarded at once.
* `408 Request Timeout`, `429 Too Many Requests`, or `503 Service Unavailable` asks to send the
  request again later, and the server did not store the entries. With `async: true` or
  `batch: true`, the worker thread [backs off](operations.html#retry-a-failing-appender), then sends
  the same entry or batch again, so that it is written once the server is back, ahead of the entries
  logged meanwhile, which wait on the queue. Once the server has answered it in this way after it
  was sent again 3 times, it is discarded, and the worker thread carries on with the next one once
  it has backed off, so that a request the server keeps turning away, such as one it answers with a
  `429` that never clears, does not hold up the others.
* Any other status, such as `500 Internal Server Error`, `502 Bad Gateway`, `504 Gateway Timeout`,
  or a redirect, is a problem with the destination too, but the entry or batch is not sent again: a
  `500` often comes again for the same request, and a proxy can answer a `502` or `504` once the
  server behind it has stored it. With `async: true` or `batch: true`, it is discarded straight
  away, and the worker thread backs off before sending the next one.

A request that the appender could not send, since it could not connect to the server (the name does
not resolve, the server cannot be reached, or it refuses the connection or does not accept it within
`open_timeout`), is sent again in the same way as a `503`, but without counting towards the 3 times:
the server has not answered it, so an outage loses no entries until the worker thread gives up. A
request that failed once it was sent, such as one whose answer did not come within `read_timeout`,
or whose connection was reset, is discarded instead, after the same back-off, since the server may
have stored its entries. While a flush is waiting, such as the one at exit, a request that fails is
discarded rather than sent again.

The worker thread stops for good after `async_max_retries` (default `100`) failures in a row,
discarding the entry or batch it was sending; pass `async_max_retries: -1` to keep trying through a
long outage.

The discarded entries are counted as `failed` in `SemanticLogger.stats`, and reported to the internal
logger with the status code, the url without its credentials, and the start of the response body.
Without `async:` or `batch:`, each request that fails is reported in the same way.

While the worker thread backs off, the entries logged meanwhile wait on the appender's own queue, as
they already did while the server could not be reached. Once that queue is full (`max_queue_size`,
default `10,000`), the thread that writes to every appender waits for room in it, so the other
appenders stop receiving entries as well, and once the main queue is full too, so does every logging
call, until the server accepts requests again. To keep logging while the server is unavailable, add
the appender with `non_blocking: true` as well, so that once its queue is full, its entries are
dropped and counted instead (see
[Drop messages instead of blocking](operations.html#drop-messages-instead-of-blocking)):

~~~ruby
SemanticLogger.add_appender(
  appender:     :http,
  url:          "http://localhost:8088/path",
  batch:        true,
  non_blocking: true
)
~~~

When the server rejects every request, for example because the password or the path is wrong, each
batch is discarded with its first request, and reported once.

### TCP Appender (+SSL)

The TCP appender sends JSON or other formatted messages to services that accept log messages over TCP,
optionally with SSL:

~~~ruby
# Plain TCP:
SemanticLogger.add_appender(appender: :tcp, server: "localhost:8088")

# TCP with SSL:
SemanticLogger.add_appender(appender: :tcp, server: "localhost:8088", ssl: true)

# With a self-signed certificate, or one from a private certificate authority, trust that
# certificate instead of disabling verification:
SemanticLogger.add_appender(
  appender: :tcp,
  server:   "localhost:8088",
  ssl:      {ca_file: "/path/to/ca.pem"}
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
such as `:default` or `:color`, enable `escape_control_chars` so a newline in the logged data cannot
forge a record. Those formatters still write an entry with an exception over several lines (the
exception, then its backtrace), so a receiver that frames records by newline splits such an entry;
use the JSON formatter or the `:syslog` formatter when every record must be a single line:

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
SemanticLogger.add_appender(appender: :udp, server: "localhost:8088", metrics: false)
~~~

The `server:` is `"host:port"`. Write an IPv6 address in brackets, as a URL does, such as
`server: "[::1]:8088"`. A host name with an IPv4 address is sent to over IPv4, even when the
resolver returns its IPv6 address first, as it does for `localhost` on macOS. It is sent to over
IPv6 when it has only IPv6 addresses, or when the socket cannot connect over IPv4, such as on a
machine with no IPv4 route. Its IPv6 addresses are looked up only when the resolver answers that it
has no IPv4 address, or when the socket cannot connect to any of them. When looking up its IPv4
addresses fails for another reason, such as a resolver that does not answer in time, adding or
reopening the appender raises that `SocketError`. On Linux with glibc, that includes a name whose
only addresses are IPv6 ones in `/etc/hosts`, while DNS cannot be reached: its IPv4 lookup then
fails, rather than finding no address. On Ruby 3.2 and JRuby, whose `SocketError` does not say why
a lookup failed, the IPv6 addresses are looked up after any failure.

Pass `metrics: true` to also send metric-only entries, which have a metric but no message and no
exception. Without `metrics:`, it sends them and reports a
[deprecation warning](upgrading.html#seeing-deprecation-warnings), since v6 leaves them out by default.

Customize the message with a formatter:

~~~ruby
formatter = Proc.new do |log, logger|
  h = log.to_h(logger.host, logger.application)
  h[:timestamp] = log.time.utc.to_f # seconds since epoch
  h.to_json
end

SemanticLogger.add_appender(appender: :udp, server: "localhost:8088", formatter: formatter, metrics: false)
~~~

### Syslog

Log to a local Syslog daemon. Since Ruby 3.4 `syslog` is a bundled gem, so add `gem "syslog"` to the
Gemfile:

~~~ruby
SemanticLogger.add_appender(appender: :syslog)
~~~

Log to a remote Syslog server over TCP (the `net_tcp_client` and `syslog_protocol` gems are required).
The default packet size is 1024 bytes:

~~~ruby
SemanticLogger.add_appender(appender: :syslog, url: "tcp://myloghost:514", max_size: 2048)
~~~

`max_size` also applies when `formatter:` names the `:syslog` or `:syslog_cee` formatter. A
formatter passed as an instance uses its own `max_size`, which also defaults to 1024 bytes:

~~~ruby
SemanticLogger.add_appender(appender: :syslog, url: "udp://myloghost:514", formatter: :syslog_cee, max_size: 2048)
~~~

Or over UDP (the `syslog_protocol` gem is required):

~~~ruby
SemanticLogger.add_appender(appender: :syslog, url: "udp://myloghost:514")
~~~

Set the facility with one of Ruby's `::Syslog::LOG_*` facility constants (the default is
`::Syslog::LOG_USER`). For remote syslog without the `syslog` gem, the same constants are available
from `SemanticLogger::Formatters::Syslog`, for example `SemanticLogger::Formatters::Syslog::LOG_LOCAL0`:

~~~ruby
SemanticLogger.add_appender(appender: :syslog, url: "udp://myloghost:514", facility: ::Syslog::LOG_LOCAL0)
~~~

The `facility:`, `level_map:`, and `max_size:` options also apply when `formatter:` names the `:syslog` or
`:syslog_cee` formatter, for example `formatter: :syslog_cee`. Options given to the formatter itself,
as in `formatter: {syslog: {facility: ::Syslog::LOG_LOCAL1}}`, take precedence. A formatter passed
as an instance keeps its own settings.

Over TCP or UDP, each record's header holds the host name and the application name, as its tag. The
`syslog_protocol` gem that builds the record allows only printable ASCII characters other than the
space in either, and up to 32 in the tag, so any other character is left out, and the application
name is cut to 32 characters:
an application named `"Café Orders"` is written as `CafOrders`. A name with no character left is
written as `localhost` or `SemanticLogger`.

Add a filter to exclude noisy entries such as health checks:

~~~ruby
SemanticLogger.add_appender(
  appender: :syslog,
  url:      "udp://myloghost:514",
  filter:   Proc.new { |log| log.message !~ /(health_check|Not logged in)/ }
)
~~~

Syslog frames each record, so embedded newlines or other control characters in untrusted data could
forge or split records. The syslog formatters therefore escape control characters by default. The
`:syslog` formatter also escapes the newlines between an exception and its backtrace lines (written
as `\n`), so that an entry with an exception is a single line. To pass control characters through
unchanged, which also restores the multi-line exception layout:

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
written to a daily index named `semantic_logger-YYYY.MM.DD`. `index:` sets the name before the date,
and `date_pattern:` the date, such as `"%Y.%m"` for a monthly index:

~~~ruby
SemanticLogger.add_appender(
  appender: :elasticsearch,
  url:      "http://localhost:9200",
  index:    "my-index"
)
~~~

With `data_stream: true`, entries are written to the data stream that `index:` names, without a
date, and the default formatter writes the time under `@timestamp`, which a data stream requires.
Elasticsearch creates the data stream with the first entry when an index template that enables data
streams matches its name; otherwise it creates an ordinary index of that name:

~~~ruby
SemanticLogger.add_appender(
  appender:    :elasticsearch,
  url:         "http://localhost:9200",
  index:       "my-logs",
  data_stream: true
)
~~~

The appender sends its entries in bulk requests, a batch at a time by default. When Elasticsearch
indexes only some of the entries of a request, the entries it indexed are not sent again. It rejects
an entry with status 429 when its write queue is full, so those entries alone are sent again, up to 3
times, after waiting 0.2, 0.4, then 0.8 seconds. That holds up the thread that writes the entries for
waits of at most 1.4 seconds for a request, plus up to 3 more bulk requests. It is the appender's own
thread when it writes in batches, as it does by default, or with `async: true`. With `batch: false`,
and without `async: true`, it is the thread that writes to every appender, so the other appenders
wait too; with `SemanticLogger.sync!`, that is the thread that logged, and every other thread that
logs waits for it. The entries still not indexed are discarded, and reported to the internal logger.

For an end-to-end walkthrough with Kibana, see [Centralized Logging](operations.html#centralized-logging).

### OpenSearch

Forward all log entries to OpenSearch, for example AWS OpenSearch (requires the `opensearch-ruby`
gem). OpenSearch is a fork of Elasticsearch and uses the same bulk indexing API, so this appender
accepts the same options as [Elasticsearch](#elasticsearch), and sends again the entries rejected
with status 429 in the same way. Use it instead of the Elasticsearch appender when talking to an
OpenSearch server, since recent `elasticsearch` gems reject non-Elasticsearch servers with an
`Elasticsearch::UnsupportedProductError`:

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

### Splunk SDK

> **Deprecated:** `appender: :splunk` is deprecated and will be removed in v6. Use the
> [HTTP Event Collector](#splunk-http) (`appender: :splunk_http`) or the
> [TCP appender](#tcp-appender-ssl) instead.

`appender: :splunk` submits entries through the `splunk-sdk-ruby` gem to the Splunk management
port. That gem was last released in 2015 and does not verify the server's TLS certificate, so the
connection, including the login credentials, is open to interception.

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
log messages. The ingestion path is appended to the url, so a query string on the url is kept and sent
with every push.

Each entry is a stream whose labels are `pid`, `host`, `application`, `environment`, `level`,
`thread`, `tags` (as JSON), each named tag, and each value an `on_log` subscriber adds to the context.
Its line is the message. Its structured metadata holds each payload key, and these fields when the
entry has the value:

| Field | Value |
|-------|-------|
| `metric`, `metric_value`, `dimensions` | The metric's name, its amount, and its dimensions as JSON. |
| `duration`, `duration_human` | The duration in milliseconds, from the `measure_*` methods, and as text. |
| `exception_name`, `exception_message` | The class and message of the logged exception. |
| `stack_trace` | Its backtrace, followed by each exception that caused it. |

Structured metadata holds only Strings, so a nested value in the payload is written as JSON, and any
other value as its text. A payload key named like one of these fields is written with a `payload_`
prefix, as in `payload_duration`, whether or not the entry has that field, so that logged data cannot
replace them. Loki stores a name with characters other than ASCII letters and digits with each run of
them replaced by `_`, so a key that it would store under one of these names, such as `metric.value`,
is prefixed too, and written as Loki stores it: `payload_metric_value`. When another payload key has
that name once Loki has stored it, the prefix is added again, as in `payload_payload_metric_value`,
so that Loki keeps the value of each prefixed key. A key that is exactly one of these names gets the
name with one prefix, so `payload_metric_value` always holds the payload's `metric_value`. Loki keeps
only one value of other payload keys that it stores alike, such as `a.b` and `a_b`. Loki rejects a
payload key without an ASCII letter or digit, such as an empty key or `-`, so it is prefixed too, and
written as `payload_`.

Loki also rejects a label name other than an ASCII letter or underscore followed by letters, digits,
and underscores. A named tag or context key that it would reject, such as `request-id` or `1st`, is
written under the name Loki would give it as structured metadata, such as `request_id` or `key_1st`,
and an empty key as `key_`. When another label already has that name with another value, a number is
added, as in `request_id_2`. A named tag or context value that is nil is left out.

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
as the record body, and the named tags and payload as record attributes. The appender registers a
`SemanticLogger.on_log` subscriber that captures the current OpenTelemetry context as each entry is
logged, so log records are correlated with the active trace and span.

For example, inside a span:

~~~ruby
SemanticLogger.named_tagged(request_id: "abc") do
  logger.info("Created user", user_id: 42)
end
~~~

is emitted as a record with the severity text `info` and number `9`, the trace and span ids of that
span, and:

~~~
body:       "Created user"
attributes: {"request_id" => "abc", "user_id" => 42, "semantic_logger.name" => "UserService",
             "thread.name" => "puma srv tp 001", "process.pid" => 12345}
~~~

Each named tag and payload key is an attribute of its own; a payload key takes precedence over a
named tag of the same name. An entry without a message, such as `logger.error(exception)`, has no
body. Semantic Logger adds these attributes when the entry has the value:

| Attribute | Value |
|-----------|-------|
| `exception.type`, `exception.message` | The class and message of the logged exception. |
| `exception.stacktrace` | Its backtrace, followed by each exception that caused it. |
| `code.file.path`, `code.line.number` | Where the entry was logged, when it has a call site (see [`call_site_level`](config.html#recording-where-each-entry-was-logged)) or captured a backtrace (see `backtrace_level`). |
| `code.function.name` | The method that logged the entry, such as `Order#submit`, when it has a call site. |
| `thread.name` | The name of the thread that logged the entry, or its object id when it has none. |
| `process.pid` | The id of the process that logged the entry. |
| `semantic_logger.name` | The logger's name, usually the class name. |
| `semantic_logger.tags` | The tags, as an array. |
| `semantic_logger.duration_ms` | The duration in milliseconds, from the `measure_*` methods. |
| `semantic_logger.metric`, `semantic_logger.metric_amount` | The metric name and amount. |
| `semantic_logger.dimensions.<key>` | Each of the metric's dimensions, such as `semantic_logger.dimensions.region`. |

The first six rows use the names from the
[OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/). A named tag or
payload key named like one of these attributes is prefixed with its source, as in
`payload.exception.type`, so that logged data cannot replace or forge them.

OpenTelemetry attribute values are Strings, Integers, Floats, booleans, or arrays of one of those
types, so a nested Hash, Array, `Struct`, or `Set` is sent as JSON, any other value, such as a Symbol
or a Time, as its `#to_s`, every element of an array that mixes types, such as `[1, "two"]`, as a
String, and a `nil` value is left out.

The host name, application, and environment are not attributes: OpenTelemetry reports them once per
export, in its resource, rather than on every record. Set them with the standard environment
variables:

~~~
OTEL_SERVICE_NAME=my_app
OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=production,host.name=web-1
~~~

The process id is an attribute because the resource holds the id of the process that configured
OpenTelemetry, which is wrong for a worker forked from it, for example by Puma or Unicorn.

| Option | Description |
|--------|-------------|
| `name` | Instrumentation scope name reported to OpenTelemetry. Defaults to `"SemanticLogger"`. |
| `version` | Instrumentation scope version. Defaults to the Semantic Logger gem version. |
| `metrics` | Whether to also send metric-only entries, as log records with no body. Defaults to `false`. |

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

> **Note:** These appenders forward the payload and named tags. Name the keys whose values must not
> be sent with [`SemanticLogger.sensitive_keys`](security.html#redacting-sensitive-data), and keep
> sensitive information out of messages and tags, which are sent as they are.

The `:bugsnag`, `:sentry_ruby`, `:honeybadger`, and `:honeybadger_insights` appenders send the text
of an entry, such as its message, payload, and named tags, converted to valid UTF-8, as the JSON
formatters write it: binary text, such as a response body, is read as the UTF-8 it usually holds,
and invalid bytes are dropped. A Hash or Array nested more than 32 levels deep, or that holds itself,
is cut off there with a placeholder such as `"#<Hash nested too deeply>"`, as the JSON formatters cut
it off. Any other object in the data is handed over unchanged, for the service to write. When an
entry has an exception, `:bugsnag`, `:sentry_ruby`, and `:honeybadger` report that exception itself,
whose message the service's gem cleans.

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

Use the `sentry-ruby` gem and the corresponding appender:

~~~ruby
SemanticLogger.add_appender(appender: :sentry_ruby)
~~~

> **Deprecated:** the older `appender: :sentry` (backed by the end-of-life `sentry-raven` gem) still
> works but is deprecated and will be removed in v6. Switch to `appender: :sentry_ruby`.

Each entry is sent with the Sentry context of the thread (or fiber) that logged it: the user, tags,
contexts, breadcrumbs, trace, and event processors that `sentry-ruby`, `sentry-rails`, or the
application set for it, such as with `Sentry.set_user`. The request itself (its url, headers, and
body) is left out, since Sentry reads the request body to send it, which the appender thread must not
do while the request is using it; the errors that `sentry-rails` reports itself still include it. The appender sends the entry from its own thread, so it
registers an `on_log` subscriber that keeps a copy of that Sentry scope with each entry it will send
(with `Log#capture`, so that no formatter writes it), as the entry is logged.

Some logging context is also forwarded to Sentry, added to that of the thread:

* From named tags, `transaction_name`. See
  <https://docs.sentry.io/platforms/ruby/enriching-events/transaction-name/>.
* From named tags, `user` is built from the `user_id`, `username`, `user_email`, and
  `ip_address` keys, plus any `user` key that is itself a hash. Its fields replace the same fields
  of the thread's Sentry user. See
  <https://docs.sentry.io/platforms/ruby/enriching-events/identify-user/>.
* From named tags, `fingerprint` (an Array of Strings, Symbols, or numbers) configures grouping
  granularity. See
  <https://docs.sentry.io/platforms/ruby/usage/sdk-fingerprinting/>.
* Named tags are sent as Sentry tags. See
  <https://docs.sentry.io/platforms/ruby/enriching-events/tags/>.
* Unnamed tags are sent as the `:tag` tag, separated by commas.
* Everything else from the payload and context is added to `extras`, including a value of the
  wrong type for one of the keys above.

> **Deprecated:** the `user` and `fingerprint` keys are also still taken from the payload, but that
> is deprecated and will be removed in v6, since the payload often holds untrusted data, such as a
> request body, that could set the user an error is reported for. Set them with named tags. The
> named tags win over the payload, and a user field is only taken from the payload when it is a
> String, Symbol, or Integer.

~~~ruby
SemanticLogger.tagged(transaction_name: "foo", user_id: 42, username: "joe", fingerprint: ["bar"], baz: "quz") do
  logger.error("some message")
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

> **Deprecated:** `appender: :new_relic` (error events via `newrelic_rpm`) is deprecated and will be
> removed in v6. To forward log entries to New Relic, use `appender: :new_relic_logs` instead.

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

It sends the whole entry, payload included, as it was logged: `on_log` subscribers run before
[`SemanticLogger.sensitive_keys`](security.html#redacting-sensitive-data) redacts the entry, so its
values are not filtered. Send only the fields Rollbar needs when entries can hold sensitive values.

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

MongoDB stores only valid UTF-8 text, and keys without NUL bytes. An entry holding other text, such
as a binary response body in its payload, or an exception message that quotes invalid input, is
stored with that text converted, as the JSON formatters write it: binary text is read as the UTF-8 it
usually holds, invalid bytes are dropped, and NUL bytes are removed from keys. Such an entry nested
more than 32 levels deep is cut off there, as the JSON formatters cut it off.

### Apache Kafka

Publish log entries to an Apache Kafka broker (requires the `ruby-kafka` gem):

~~~ruby
SemanticLogger.add_appender(
  appender:     :kafka,
  seed_brokers: ["kafka1:9092", "kafka2:9092"],
  metrics:      false
)
~~~

Pass `metrics: true` to also publish metric-only entries, which have a metric but no message and no
exception. Without `metrics:`, it publishes them and reports a
[deprecation warning](upgrading.html#seeing-deprecation-warnings), since v6 leaves them out by default.

### RabbitMQ (AMQP)

Stream log entries through a queue on a RabbitMQ broker (requires the `bunny` gem):

~~~ruby
SemanticLogger.add_appender(
  appender:      :rabbitmq,
  queue_name:    "semantic_logger",
  rabbitmq_host: "localhost",
  username:      "the-username",
  password:      "the-password",
  metrics:       false
)
~~~

Pass `metrics: true` to also send metric-only entries, which have a metric but no message and no
exception. Without `metrics:`, it sends them and reports a
[deprecation warning](upgrading.html#seeing-deprecation-warnings), since v6 leaves them out by default.

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
