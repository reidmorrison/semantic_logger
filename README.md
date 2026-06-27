# Semantic Logger
[![Gem Version](https://img.shields.io/gem/v/semantic_logger.svg)](https://rubygems.org/gems/semantic_logger) [![Build Status](https://github.com/reidmorrison/semantic_logger/workflows/build/badge.svg)](https://github.com/reidmorrison/semantic_logger/actions?query=workflow%3Abuild) [![Downloads](https://img.shields.io/gem/dt/semantic_logger.svg)](https://rubygems.org/gems/semantic_logger) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Production%20Ready-blue.svg)

Semantic Logger is a high-performance, asynchronous structured logging framework for Ruby
and Rails.

It differs from ordinary loggers in two important ways:

1. **It logs structured data, not just strings.** Along with the text message, each log entry can
   carry a payload (any Hash), an exception, a duration, metrics, and tags. That data is preserved
   all the way to the destination, so it stays searchable instead of being flattened into text.
2. **It logs asynchronously.** Log events are pushed onto an in-memory queue and written to their
   destinations by a separate background thread, so your application is not blocked while logs are
   written. Semantic Logger can log thousands of lines per second without slowing the application
   down.

```ruby
require "semantic_logger"

SemanticLogger.default_level = :info
SemanticLogger.add_appender(io: $stdout, formatter: :color)

logger = SemanticLogger["MyApp"]

# A plain message, plus structured data that stays searchable
logger.info("Queried users table", duration: 54, result: :ok, table: "users")
```

When running Rails, use
[rails_semantic_logger](https://github.com/reidmorrison/rails_semantic_logger) instead, since it
replaces the Rails default logger with Semantic Logger automatically.

## Documentation

Start with the [Introduction](https://logger.rocketjob.io/), then the
[Programmer's Guide](https://logger.rocketjob.io/api.html).

* Full guide: [https://logger.rocketjob.io/](https://logger.rocketjob.io/)

## Logging Destinations

Logging to the following destinations are all supported "out-of-the-box":

* File
* Screen
* ElasticSearch. (Use with Kibana for Dashboards and Visualizations)
* Graylog
* BugSnag
* NewRelic
* Splunk
* MongoDB
* Honeybadger (exceptions and events)
* Sentry (both with legacy `sentry-raven` and modern `sentry-ruby` gem)
* HTTP
* TCP
* UDP
* Syslog
* CloudWatch Logs
* OpenTelemetry
* Add any existing Ruby logger as another destination.
* Roll-your-own

Semantic Logger is capable of logging thousands of lines per second without slowing
down the application. Traditional logging systems make the application wait while
the log information is being saved. Semantic Logger avoids this slowdown by pushing
log events to an in-memory queue that is serviced by a separate thread that only
handles saving log information to multiple destinations / appenders.

## Rails

When running Rails, use [rails_semantic_logger](http://github.com/reidmorrison/rails_semantic_logger)
instead of Semantic Logger directly since it will automatically replace the Rails default logger with Semantic Logger.

## Rocket Job

Checkout the sister project [Rocket Job](http://rocketjob.io): Ruby's missing batch system.

Fully supports Semantic Logger when running jobs in the background. Complete support for job metrics
sent via Semantic Logger to your favorite dashboards.

## Optional Dependencies

The following gems are only required when their corresponding appenders are being used,
and are therefore not automatically included by this gem:
- Bugsnag Appender: gem 'bugsnag'
- MongoDB Appender: gem 'mongo' 1.9.2 or above
- Honeybadger Appender: gem 'honeybadger'
- HoneybadgerInsights Appender: gem 'honeybadger'
- NewRelic Appender: gem 'newrelic_rpm'
- NewRelicLogs Appender: gem 'newrelic_rpm'
- Syslog Appender: gem 'syslog_protocol' 0.9.2 or above
- Syslog Appender to a remote syslogng server over TCP or UDP: gem 'net_tcp_client'
- Splunk Appender: gem 'splunk-sdk-ruby'
- Elasticsearch Appender: gem 'elasticsearch'
- OpenSearch Appender: gem 'opensearch-ruby'
- Kafka Appender: gem 'ruby-kafka'
- Legacy Sentry Appender: gem 'sentry-raven' (deprecated)
- Sentry Appender: gem 'sentry-ruby'
- OpenTelemetry Appender: gem 'opentelemetry-logs-sdk' (plus an exporter, e.g. 'opentelemetry-exporter-otlp-logs')

## Upgrading to Semantic Logger v5.0

- Ruby 3.2 is now the minimum runtime version.

### Appenders are now reopened automatically after a fork

Previously, after a process forked (Puma, Unicorn, Resque, Spring, Phusion
Passenger, parallel tests, etc.) you had to call `SemanticLogger.reopen` yourself
in an `after_fork` style hook, otherwise logging would silently stop in the child.

As of v5, Semantic Logger installs a `Process._fork` hook (Ruby 3.1+) that calls
`SemanticLogger.reopen` automatically in the child process after `fork`,
`Process.daemon`, `IO.popen`, `Kernel#system`, and backticks. No configuration is
required for the common cases.

**Recommended:** remove all of your existing manual reopen calls. For example,
delete code such as:

~~~ruby
# config/unicorn.conf.rb
after_fork do |server, worker|
  SemanticLogger.reopen
end

# config/puma.rb
before_worker_boot do
  SemanticLogger.reopen
end

# Resque / Spring / Passenger
Resque.after_fork  { SemanticLogger.reopen }
Spring.after_fork  { SemanticLogger.reopen }
PhusionPassenger.on_event(:starting_worker_process) { |forked| SemanticLogger.reopen if forked }
~~~

Leaving these in place is safe, since `SemanticLogger.reopen` now no-ops when it
has already run in the current process after a fork, but they are no longer needed.

**Opt out:** to restore the previous behavior and manage reopen yourself, disable
the automatic hook during application boot:

~~~ruby
SemanticLogger.reopen_on_fork = false
~~~

If you need to reopen within the same process (for example after an external log
rotation that did not fork), call `SemanticLogger.reopen(force: true)` to bypass
the per-process guard.

If you use Rails Semantic Logger, upgrade it alongside Semantic Logger v5.

## Upgrading

See the [Upgrading Guide](https://logger.rocketjob.io/upgrading.html) for instructions on
upgrading between major versions.

## Install

    gem install semantic_logger

To configure a stand-alone application for Semantic Logger:

~~~ruby
require 'semantic_logger'

# Set the global default log level
SemanticLogger.default_level = :trace

# Log to a file, and use the colorized formatter
SemanticLogger.add_appender(file_name: 'development.log', formatter: :color)
~~~

If running rails, see: [Semantic Logger Rails](https://logger.rocketjob.io/rails.html)

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to set up the project, run the
tests, and an overview of the architecture, including a class diagram.

## Author

[Reid Morrison](https://github.com/reidmorrison)

[Contributors](https://github.com/reidmorrison/semantic_logger/graphs/contributors)

## Versioning

This project uses [Semantic Versioning](http://semver.org/).
