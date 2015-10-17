# semantic_logger
![](https://img.shields.io/gem/v/semantic_logger.svg) ![](https://img.shields.io/travis/reidmorrison/semantic_logger.svg) ![](https://img.shields.io/gem/dt/semantic_logger.svg) ![](https://img.shields.io/badge/status-production%20ready-blue.svg)

Low latency, high throughput, enterprise-scale logging system for Ruby

* http://github.com/reidmorrison/semantic_logger

## Documentation

[Semantic Logger Guide](http://reidmorrison.github.io/semantic_logger)

[Reference Documentation](http://www.rubydoc.info/gems/semantic_logger/)

## Supports

Logging to the following destinations are all supported "out-of-the-box":

* File
* Screen
* MongoDB
* BugSnag
* NewRelic
* Splunk
* Syslog
* Roll-your-own

Semantic Logger is capable of logging thousands of lines per second without slowing
down the application. Traditional logging systems make the application wait while
the log information is being saved. Semantic Logger avoids this slowdown by pushing
log events to an in-memory queue that is serviced by a separate thread that only
handles saving log information to multiple destinations at the same time.

## Dependencies

Semantic Logger is tested and supported on the following Ruby platforms:
- Ruby 2.0 and above
- JRuby 1.7 and above
- JRuby 9.0.0.0 and above
- Rubinius 2.5 and above

The following gems are only required when their corresponding appenders are being used,
and are therefore not automatically included by this gem:
- Bugsnag Appender: gem 'bugsnag'
- MongoDB Appender: gem 'mongo' 1.9.2 or above
- NewRelic Appender: gem 'newrelic_rpm'
- Syslog Appender: gem 'syslog_protocol' 0.9.2 or above
- Syslog Appender to a remote syslogng server over TCP or UDP: gem 'net_tcp_client'
- Splunk Appender: gem 'splunk-sdk-ruby'

## Install

    gem install semantic_logger

## Upgrade Notes:

### V2.10

Ruby 1.8 is no longer supported, see [Ruby 1.8.7 EOL](https://www.ruby-lang.org/en/news/2014/07/01/eol-for-1-8-7-and-1-9-2/)

### V2.0

Rails logging is no longer automatically replaced when including SemanticLogger.
Include the [rails_semantic_logger](http://github.com/reidmorrison/rails_semantic_logger)
gem to replace the Rails default logger with SemanticLogger

## Author

[Reid Morrison](https://github.com/reidmorrison)

[Contributors](https://github.com/reidmorrison/semantic_logger/graphs/contributors)

## Versioning

This project uses [Semantic Versioning](http://semver.org/).
