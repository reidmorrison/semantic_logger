# Semantic Logger
[![Gem Version](https://img.shields.io/gem/v/semantic_logger.svg)](https://rubygems.org/gems/semantic_logger) [![Build Status](https://travis-ci.org/rocketjob/semantic_logger.svg?branch=master)](https://travis-ci.org/rocketjob/semantic_logger) [![Downloads](https://img.shields.io/gem/dt/semantic_logger.svg)](https://rubygems.org/gems/semantic_logger) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Production%20Ready-blue.svg) [![Gitter chat](https://img.shields.io/badge/IRC%20(gitter)-Support-brightgreen.svg)](https://gitter.im/rocketjob/support)

Semantic Logger is a feature rich logging framework, and replacement for existing Ruby & Rails loggers.  

* https://rocketjob.github.io/semantic_logger/

## Documentation

[Semantic Logger Guide](http://rocketjob.github.io/semantic_logger)

[Reference Documentation](http://www.rubydoc.info/gems/semantic_logger/)

## Upgrading to Semantic Logger v4.4

With some forking frameworks it is necessary to call `reopen` after the fork. With v4.4 the
workaround for Ruby 2.5 crashes is no longer needed. 
I.e. Please remove the following line if being called anywhere:

~~~ruby
SemanticLogger::Processor.instance.instance_variable_set(:@queue, Queue.new)
~~~

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
* Honeybadger
* Sentry
* HTTP
* TCP
* UDP
* Syslog
* Add any existing Ruby logger as another destination.
* Roll-your-own

Semantic Logger is capable of logging thousands of lines per second without slowing
down the application. Traditional logging systems make the application wait while
the log information is being saved. Semantic Logger avoids this slowdown by pushing
log events to an in-memory queue that is serviced by a separate thread that only
handles saving log information to multiple destinations / appenders.

## Rails

When running Rails, use [rails_semantic_logger](http://github.com/rocketjob/rails_semantic_logger)
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
- NewRelic Appender: gem 'newrelic_rpm'
- Syslog Appender: gem 'syslog_protocol' 0.9.2 or above
- Syslog Appender to a remote syslogng server over TCP or UDP: gem 'net_tcp_client'
- Splunk Appender: gem 'splunk-sdk-ruby'
- Elasticsearch Appender: gem 'elasticsearch'
- Kafka Appender: gem 'ruby-kafka'

## V4 Upgrade notes

The following changes need to be made when upgrading to V4:
- Ruby V2.3 / JRuby V9.1 is now the minimum runtime version.
- Replace calls to Logger#with_payload with SemanticLogger.named_tagged.
- Replace calls to Logger#payload with SemanticLogger.named_tags.
- MongoDB Appender requires Mongo Ruby Client V2 or greater.
- Appenders now write payload data in a seperate :payload tag instead of mixing them
  directly into the root elements to avoid name clashes.

As a result any calls like the following:

~~~ruby
logger.debug foo: 'foo', bar: 'bar'
~~~

Must be replaced with the following in v4:

~~~ruby
logger.debug payload: {foo: 'foo', bar: 'bar'}
~~~

Similarly, for measure blocks:

~~~ruby
logger.measure_info('How long is the sleep', foo: 'foo', bar: 'bar') { sleep 1 } 
~~~

Must be replaced with the following in v4:

~~~ruby
logger.measure_info('How long is the sleep', payload: {foo: 'foo', bar: 'bar'}) { sleep 1 } 
~~~

The common log call has not changed, and the payload is still logged directly: 

~~~ruby
logger.debug('log this', foo: 'foo', bar: 'bar')
~~~

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

If running rails, see: [Semantic Logger Rails](http://rocketjob.github.io/semantic_logger/rails.html)

## Author

[Reid Morrison](https://github.com/reidmorrison)

[Contributors](https://github.com/rocketjob/semantic_logger/graphs/contributors)

## Versioning

This project uses [Semantic Versioning](http://semver.org/).
