---
layout: default
title: ClickHouse
description: >-
  Send Semantic Logger's log entries and metrics to ClickHouse through the OpenTelemetry
  Collector, with a quick start in Docker, the queries to check that the data arrived, and
  how to run it in production.
---

Semantic Logger sends log entries and metrics as OpenTelemetry (OTLP), which the OpenTelemetry
Collector writes to ClickHouse with its `clickhouse` exporter. No OpenTelemetry gems are needed in the
application: `appender: :otlp` and `metric: :otlp` write OTLP themselves. Grafana, with the ClickHouse
plugin, shows the logs and graphs the metrics.

~~~
application --OTLP/HTTP--> OpenTelemetry Collector --> ClickHouse <-- Grafana
~~~

## Quick start

The quick start runs ClickHouse, the Collector, and Grafana in Docker, for development or to try it
out. It needs Docker with Compose, and a checkout of Semantic Logger for its
[examples/clickhouse](https://github.com/reidmorrison/semantic_logger/tree/main/examples/clickhouse)
directory.

### 1. Start the stack

~~~shell
docker compose -f examples/clickhouse/compose.yml up -d --wait
~~~

[compose.yml](https://github.com/reidmorrison/semantic_logger/blob/main/examples/clickhouse/compose.yml)
starts:

| Service | Image | On this host |
|---------|-------|--------------|
| ClickHouse | `clickhouse/clickhouse-server:26.8.46.6` | SQL over HTTP on `localhost:8123`, user and password `otel` |
| OpenTelemetry Collector | `otel/opentelemetry-collector-contrib:0.166.0` | OTLP/HTTP on `localhost:4318` |
| Grafana | `grafana/grafana:13.3.2`, with `grafana-clickhouse-datasource` 4.24.0 | `localhost:3000`, user and password `admin` |

When another stack has these ports, set `CLICKHOUSE_PORT`, `OTLP_PORT`, or `GRAFANA_PORT` before
`up`, and point the application at the Collector with `OTEL_EXPORTER_OTLP_ENDPOINT`. ClickHouse needs
about 1 GB of memory: give Docker more, such as with `colima start --memory 4`, when it stops with
`memory limit exceeded`.

### 2. The Collector

[otel-collector.yaml](https://github.com/reidmorrison/semantic_logger/blob/main/examples/clickhouse/otel-collector.yaml)
receives OTLP/HTTP and writes logs and metrics to the `otel` database, creating its tables. In
short, without its timeout and retry settings:

~~~yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

exporters:
  clickhouse:
    endpoint: tcp://clickhouse:9000?dial_timeout=10s
    database: otel
    username: otel
    password: otel
    ttl: 72h
    create_schema: true
    sending_queue:
      batch:
        flush_timeout: 1s

service:
  pipelines:
    logs:
      receivers: [otlp]
      exporters: [clickhouse]
    metrics:
      receivers: [otlp]
      exporters: [clickhouse]
~~~

`ttl` is how long rows are kept: raise it for production. `up --wait` returns once the Collector has
started, which may be a moment before it accepts connections.

### 3. The application

Send log entries and metrics to `http://localhost:4318`, the default of both appenders:

~~~ruby
SemanticLogger.application = "checkout"
SemanticLogger.environment = "development"

SemanticLogger.add_appender(appender: :otlp)
SemanticLogger.add_appender(metric: :otlp, interval: 10)

logger = SemanticLogger["Orders"]
logger.info("Created order", order_id: 42)
logger.increment("orders.created", dimensions: {plan: "pro"})
logger.time("orders.charge", dimensions: {gateway: "stripe"}) { charge(order) }
~~~

[app.rb](https://github.com/reidmorrison/semantic_logger/blob/main/examples/clickhouse/app.rb) sends
a few of each: `bundle exec ruby examples/clickhouse/app.rb`.

In Rails, with Rails Semantic Logger 6.0 or later, `bin/rails generate rails_semantic_logger:observability`
adds the same stack, with dashboards. It first runs `rails_semantic_logger:install`, which writes an
explicit `config.rails_semantic_logger.appenders` block in each environment file, unless the app
already declares its appenders, then adds the OTLP appenders to the development one:

~~~ruby
# config/environments/development.rb
config.rails_semantic_logger.appenders do |appenders|
  # The appenders that the app already writes to, such as log/development.log and the screen, then:
  appenders.add(appender: :otlp)
  appenders.add(metric: :otlp, interval: 10)
end
~~~

See [Configuring where logs go](rails.html#configuring-where-logs-go-the-appenders-block).

The [OTLP appender](appenders.html#otlp) and [OTLP metrics](metrics.html) pages describe what each
sends and their options.

### 4. Check that the data arrived

Query ClickHouse over HTTP, or open Grafana's Explore view on the ClickHouse data source:

~~~shell
curl -u otel:otel 'http://localhost:8123/?database=otel' --data-binary @- <<'SQL'
SELECT Timestamp, SeverityText, ScopeName, Body, LogAttributes
FROM otel_logs
WHERE ServiceName = 'checkout'
ORDER BY Timestamp DESC
LIMIT 20
FORMAT Vertical
SQL
~~~

The latest errors, with their exception:

~~~sql
SELECT Timestamp, ScopeName, Body, LogAttributes['exception.type'] AS type,
       LogAttributes['exception.stacktrace'] AS stacktrace
FROM otel_logs
WHERE ServiceName = 'checkout' AND SeverityNumber >= 17
ORDER BY Timestamp DESC
LIMIT 20
~~~

Every entry logged in a trace, by its trace id:

~~~sql
SELECT Timestamp, ScopeName, Body
FROM otel_logs
WHERE TraceId = '5b8efff798038103d269b633813fc60c'
ORDER BY Timestamp
~~~

A counter, `increment`, per minute:

~~~sql
SELECT toStartOfMinute(TimeUnix) AS minute, Attributes['plan'] AS plan, sum(Value) AS created
FROM otel_metrics_sum
WHERE MetricName = 'orders.created'
GROUP BY minute, plan
ORDER BY minute
~~~

Each duration, of `time`, or of `measure_*` given `metric:`, arrives as a delta base-2 exponential
histogram, in seconds.
Its 95th percentile weights each positive bucket by its count, at the bucket's middle,
2<sup>(PositiveOffset + i + 0.5) × 2<sup>-Scale</sup></sup>, which is within one bucket of the
durations recorded:

~~~sql
SELECT quantileExactWeighted(0.95)(
         pow(2, (PositiveOffset + index - 1 + 0.5) * pow(2, -Scale)), count
       ) AS p95_seconds
FROM otel_metrics_exponential_histogram
ARRAY JOIN PositiveBucketCounts AS count, arrayEnumerate(PositiveBucketCounts) AS index
WHERE MetricName = 'orders.charge' AND TimeUnix > now() - INTERVAL 1 HOUR
~~~

[examples/clickhouse/test.rb](https://github.com/reidmorrison/semantic_logger/blob/main/examples/clickhouse/test.rb)
runs this quick start, on ports of its own, and checks the rows with these queries.

Stop the stack with `docker compose -f examples/clickhouse/compose.yml down`, and add `-v` to delete
its data.

## What ClickHouse holds

| Table | Holds | From Semantic Logger |
|-------|-------|----------------------|
| `otel_logs` | One row for each log entry | `Body` the message, or an exception logged without one, as `ArgumentError: the message`; `SeverityText` and `SeverityNumber` the level; `ScopeName` the logger name; `ServiceName` the application; `LogAttributes` the payload, named tags, exception, and call site; `TraceId` and `SpanId` the trace |
| `otel_metrics_sum` | Counters, as deltas | `increment`, and a log call given `metric:` without a duration |
| `otel_metrics_exponential_histogram` | Histograms, as deltas: durations in seconds, and other values | `time`, `measure_*` given `metric:`, and `record` |

Every row also has the resource of the process: `ServiceName`, and `ResourceAttributes` with
`host.name`, `deployment.environment.name`, and `process.pid`.

## In production

In production, have Semantic Logger write only to its own host: a local file, or an OpenTelemetry
Collector on `localhost`. The agent then owns the network, its retries, and a buffer on disk, so a
ClickHouse that is down or slow never reaches the application. Run the Collector beside each
application, as a sidecar or one per host, with the `clickhouse` exporter of the quick start pointed
at your ClickHouse, and a persistent queue:

~~~yaml
extensions:
  # A directory that the Collector's user can write to, on a persistent volume.
  file_storage/queue:
    directory: /var/lib/otelcol/queue
    create_directory: true

exporters:
  clickhouse:
    # endpoint, database, username, password, ttl as above
    sending_queue:
      storage: file_storage/queue

service:
  extensions: [file_storage/queue]
~~~

Then choose how the application hands its entries to the Collector:

* **A log file (preferred)**: write `formatter: :json` to a file, and have the Collector read it with
  the `filelog` receiver of [examples/filelog/filelog.yaml](appenders.html#json-filelog), or write
  `formatter: :otlp_json_lines` and read it with the `otlpjsonfile` receiver
  ([OTLP JSON Lines](appenders.html#otlp-json-lines)). Logs pile up in the file while the Collector is
  down, and it carries on from where it was. Metrics still go over OTLP.
* **OTLP to `localhost`**: keep `appender: :otlp` and `metric: :otlp` at their default,
  `http://localhost:4318`. Add the log appender with a bounded queue that drops rather than blocks,
  so that a Collector that is down never stalls the application:

  ~~~ruby
  SemanticLogger.add_appender(appender: :otlp, non_blocking: true)
  ~~~

  Its queue holds 10,000 entries by default (`max_queue_size:`); once it is full, the entries dropped
  are counted, and reported on the internal logger. After `async_max_retries` failures in a row,
  100 by default, the appender stops for good, until the process restarts: give
  `async_max_retries: -1` to keep trying through a long outage of the Collector.
