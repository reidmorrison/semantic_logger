# Semantic Logger
[![Gem Version](https://img.shields.io/gem/v/semantic_logger.svg)](https://rubygems.org/gems/semantic_logger) [![Build Status](https://github.com/reidmorrison/semantic_logger/workflows/build/badge.svg)](https://github.com/reidmorrison/semantic_logger/actions?query=workflow%3Abuild) [![Downloads](https://img.shields.io/gem/dt/semantic_logger.svg)](https://rubygems.org/gems/semantic_logger) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Production%20Ready-blue.svg)

Semantic Logger is a feature rich logging framework, and replacement for existing Ruby & Rails loggers.

* https://logger.rocketjob.io/

## Documentation

[Semantic Logger Guide](https://logger.rocketjob.io/)

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
- Kafka Appender: gem 'ruby-kafka'
- Legacy Sentry Appender: gem 'sentry-raven' (deprecated)
- Sentry Appender: gem 'sentry-ruby'

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

## Author

[Reid Morrison](https://github.com/reidmorrison)

[Contributors](https://github.com/reidmorrison/semantic_logger/graphs/contributors)

## Versioning

This project uses [Semantic Versioning](http://semver.org/).
