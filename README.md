semantic_logger [![Build Status](https://secure.travis-ci.org/reidmorrison/semantic_logger.png?branch=master)](http://travis-ci.org/reidmorrison/semantic_logger)
===============

Next generation logging system for Ruby to support highly concurrent, high throughput, low latency systems

* http://github.com/reidmorrison/semantic_logger

## Documentation

For complete documentation see: http://reidmorrison.github.io/semantic_logger

## Dependencies

See [.travis.yml](https://github.com/reidmorrison/semantic_logger/.travis.yml) for the list of tested Ruby platforms

The following gems are only required when their corresponding appenders are being used,
and are therefore not automatically included by this gem:
- MongoDB Appender: mongo 1.9.2 or above
- Syslog Appender: syslog_protocol 0.9.2 or above
- Syslog Appender to a remote syslogng server over TCP or UDP: resilient_socket 0.5.0 or above

## Install

    gem install semantic_logger

## Upgrade Notes:

As of SemanticLogger V2.0 the Rails logging is no longer automatically replaced
when including SemanticLogger. Include the [rails_semantic_logger](http://github.com/reidmorrison/rails_semantic_logger)
gem to replace the Rails default logger with SemanticLogger

## Meta

* Code: `git clone git://github.com/reidmorrison/semantic_logger.git`
* Home: <https://github.com/reidmorrison/semantic_logger>
* Bugs: <http://github.com/reidmorrison/semantic_logger/issues>
* Gems: <http://rubygems.org/gems/semantic_logger>

This project uses [Semantic Versioning](http://semver.org/).

## Author

Reid Morrison :: reidmo@gmail.com :: @reidmorrison

## Contributors

Marc Bellingrath :: marrrc.b@gmail.com

## License

Copyright 2012, 2013, 2014 Reid Morrison

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
