semantic_logger [![Build Status](https://secure.travis-ci.org/reidmorrison/semantic_logger.png?branch=master)](http://travis-ci.org/reidmorrison/semantic_logger) ![](http://ruby-gem-downloads-badge.herokuapp.com/semantic_logger?type=total)
===============

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

## Meta

* Code: `git clone git://github.com/reidmorrison/semantic_logger.git`
* Home: <https://github.com/reidmorrison/semantic_logger>
* Bugs: <http://github.com/reidmorrison/semantic_logger/issues>
* Gems: <http://rubygems.org/gems/semantic_logger>

This project uses [Semantic Versioning](http://semver.org/).

## Author

[Reid Morrison](https://github.com/reidmorrison) :: @reidmorrison

## Contributors

* [Marc Bellingrath](https://github.com/marc)
* [Andrew Medeiros](https://github.com/amedeiros)

## License

Copyright 2012, 2013, 2014, 2015 Reid Morrison

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
