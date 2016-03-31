# Change Log
All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](http://semver.org/).

## [Unreleased]

## [3.3.0]
### Added
- Add Raw Formatter.
- Add standard application and host variables for all appenders.
- Add TCP log appender, with support for SSL connections.
- Add UDP log appender.

### Changed
- Consolidate formatter argument extraction.
- Log warning at 1,000 and info at 100 queued messages if logging appenders back up.

### Fixed
- `SemanticLogger.on_metric` when using a Symbol was not resolving to the correct namespace.
- Support global `SemanticLogger.application` and `SemanticLogger.host` in HTTP Appender

## [3.2.1] - 2016-03-08
### Fixed
- Correctly support SSL options when using https with the HTTP Appender.
- Also affects SplunkHttp and ElasticSearch appenders when using SSL.

## [3.2.0] - 2016-03-02
### Added
- New Honeybadger appender, care of [Chris Lamb](https://github.com/lambcr).
    - Send log messages to Honeybadger.

### Changed
- Upgrade native Splunk appender to current API.
- Cleanup appenders and use `should_log?`.
- Moved Thread specific logging methods to global `SemanticLogger` namespace.
    - `SemanticLogger.tagged`
    - `SemanticLogger.tags`
    - `SemanticLogger.push_tags`
    - `SemanticLogger.pop_tags`
    - `SemanticLogger.fast_tag`
- `SemanticLogger.on_metric` now takes in addition to a Proc, an object that
  responds to #call, or a Symbol naming a builtin metrics appender.
    - For example: `:new_relic`, `statsd`

### Removed
- Removed deprecated methods:
    - `SemanticLogger::Logger.appenders`
    - `SemanticLogger::Logger.cache_count`

## [3.1.0] - 2016-02-27
### Added
- Hash only log message. Example:

~~~ruby
logger.info message: 'Hello', metric: 'user/hello', duration: 25
~~~

- APIs to make `SemanticLogger::Logger` fully compatible with the Ruby `Logger`.
    - `<<`
    - `progname`, `progname=`
    - `sev_threshold`, `sev_threshold=`
    - `formatter`
    - `datetime_format`
    - `close`
    - `reopen`
    - `add`
- New Relic and Bugsnag metrics appenders.
    - Send metrics to New Relic or Bugsnag by specifying `:metric` on log entries.

### Changed
- Replaced `benchmark_info` with better named `measure_info`, etc.
    - Existing `benchmark_...` methods have been retained for backward compatibilty.
- Break out formatters into their own namespace
    - `SemanticLogger::Formatters::Color`, :color
    - `SemanticLogger::Formatters::Default`, :default
    - `SemanticLogger::Formatters::Json`, :json
- Changed `SemanticLogger.add_appender` to take hash parameters.
    - Deprecated non hash style arguments.
    - For Example:
        - `SemanticLogger.add_appender(file: 'development.log', formatter: :color)`
    - See [Appenders](http://rocketjob.github.io/semantic_logger/appenders.html)
    - Move AnsiColors into its own module: `SemanticLogger::AnsiColors`
- Appenders now use the same hash style arguments as `SemanticLogger.add_appender`.
- Appenders use the new common formatters where applicable.
- Appenders now use custom formatters as the `#call` method for better performance over blocks.
- Bugsnag appender will now forward `:fatal` errors, since some were being ignored and
  not being reported in Bugsnag. Changes in [Rails Semantic Logger](http://rocketjob.github.io/semantic_logger/rails.html)
  allow Rails messages to be sent correctly to Bugsnag.
- Use Ruby's built-in JSON library

### Fixes
- Elasticsearch Appender rotates through daily indexes without restart.

## [3.0.0] - 2016-02-08
### Added
- New Elasticsearch appender.
    - Send log messages directly to Elasticsearch.
    - Viewable and searchable in kibana.
- New HTTP(S) appender.
    - Use HTTP POST to forward log messages.
    - By default uses JSON format, and can be customized as needed.
- New Graylog appender.
    - Use HTTP POST to forward log messages.
    - By default uses JSON format, and can be customized as needed.
- Global settings for host and application names that are shared across all appenders:
    - `SemanticLogger.host`
    - `SemanticLogger.application`
- JSON output formatter.

### Changed
- All appenders must support `:filter`, and `:levels`
- Syslog appender
    - Use `:url` instead of `:server` option.
    - Specify protocol in `:uri` now instead of separately.
        - `SemanticLogger::Appender::Syslog.new(url: 'udp://myloghost:514')`
- Better logic to exclude SemanticLogger from the top of the captured backtrace.
- Better error messages when soft dependencies are not present.

## [2.21.0] - 2015-12-18
### Added
- Soft load [Awesome Print](https://github.com/michaeldv/awesome_print) if present to colorize any logged Hash data.
- `fast_tag` as a much faster alternative to `tagged` when adding just a single string to the tag list.
- Other performance improvements.

### Fixed
- Correctly log the file name and line number of the log message
  even when an exception stacktrace is logged.

## [2.20.0] - 2015-12-9
### Changed
- `SemanticLogger::Loggable`
    - Change where `#logger` is defined so that it can override any prior `#logger`
      methods or implementations.
    - Specifically needed to support replacing the built-in Rails loggers.

## [2.19.0] - 2015-12-5
### Changed
- `SemanticLogger::Loggable`
    - Add support for inheritance hierarchies so that adding to a base class
      will result in each child class logging with its own class name instead
      of the parents logger.
- Switch from `thread_safe` gem to `concurrent-ruby` gem dependency.

### Removed
- `SemanticLogger::Logger#formatter`

### Fixed
- Handle when [Awesome Print](https://github.com/michaeldv/awesome_print) fails to
  render Hash output.

## [2.18.0] - 2015-11-11
### Added
- Support logging nested exceptions, care of [Brad Pardee](https://github.com/bpardee)

### Changed
- Refactor Log struct into its own file.
- Reduce logging verbosity from SemanticLogger itself at `:debug` level.

## [2.17.0] - 2015-11-5
### Added
- Log filename and line number of log messages.
    - Use `SemanticLogger.backtrace_level` to control when it is captured.
- Improved JRuby support.
    - Support Java Exceptions that do not derive from `Exception`

### Fixed
- Handle payloads that do not respond to `#empty?`
- Suport Ruby 1.9 backtraces

## [2.16.0] - 2015-10-25
### Added
- Use [Awesome Print](https://github.com/michaeldv/awesome_print) to colorize
  Hash output, when available.
    - Thanks to [Karim Kiatlottiavi](https://github.com/constXife)

### Changed
- Moved Semantic Logger under the [Rocket Job](https://github.com/rocketjob) organization.
- Code reformatting and use MiniTest

### Fixed
- Only log the payload if it is not empty
    - Thanks to [Ben Fagin](https://github.com/UnquietCode)
- Add default index for Splunk appender
    - Thanks to [Zach Taylor](https://github.com/zach-taylor)

## [2.15.0] - 2015-07-09
### Changed
- Refine bugsnag appender messages when sending an error message without an exception.

## [2.14.0] - 2015-04-09
### Added
- New Bugsnag appender, care of [Johnathan Ludwig](https://github.com/johnathanludwig).
    - Forward log messages to Bugsnag.

### Changed
- Improve thread stack dump output.

## [2.13.1] - 2015-02-13
### Fixed
- Raise default JRuby Garbage Collection event logging minimum duration to 100ms.

## [2.13.0] - 2015-02-12
### Added
- Log JRuby Garbage Collection events.
- `SemancicLogger::Logger#silence` to change the level during the supplied block.
    - Reduce logging messages by raising the log level in the block.
- Add `:silence` option to `benchmark_...` methods to change the log level for the duration
  of the block.

## [2.12.0] - 2015-01-22
### Added
- `SemantcLogger::DebugAsTraceLogger` for existing gems that log :debug when they should be logging at :trace.
### Changed
-  Allow the log level of a specific logger to be below that of the global default.

## [2.11.0] - 2015-01-02
### Added
- Ability to increase the log level in a benchmark block when an exception is raised inside the block.

### Changed
- Switch to Minitest, removed Mocha.
- Switch to Net::TCPClient for Syslog.
- Add support to re-open syslog, splunk, and mongodb after a process fork.

## [2.10.0] - 2014-07-29
### Added
- New Splunk appender.
    - Send log messages directly to Splunk using the `splunk` gem.
    - Thanks to [Andrew Medeiros](https://github.com/amedeiros).
- Add filters at the appender level.
    - Each appender can have its own filter.

### Removed
- Dropped support for Ruby 1.8.

### Fixed
- Allow use of % in the message string.
    - Syslog behaves like printf which causes an ArgumentError any time a % is seen in the printed log.
    - Thanks to [Leo Correa](https://github.com/Tonkpils)
- Tagged logging when tags consist of arrays of arrays.


## [2.9.0] - 2014-06-25
### Added
- NewRelic appender
    - Send :error and :fatal log messages directly to New Relic using the `newrelic_rpm` gem.
    - Thanks to [Marc Bellingraths](https://github.com/marc).

## [2.8.0] - 2014-04-21
### Added
- Use UNIX signals to change the process log level at runtime.
- Add filtering at both the logger and appender level.

### Changed
- Replace mongo appender safe option with write_concern
- Appenders can now specify which log messages to include for that appender.

## [2.7.0] - 2014-03-07
### Added
- Add support for metrics when calling benchmark methods.
- Set Java thread name under JRuby.

### Changed
- Set appender thread name and increase max length logged to file for the thread name.

## [2.6.0] - 2013-12-10
- Fix Java nil pointer exception on JRuby due to tags array being used concurrently by multiple threads.
    - Use clone to create a dedicated copy for the appender thread

## [2.5.0] - 2013-11-08
- Add support for naming a thread so that all log entries in that thread have the same thread name.

### Changed
- Any calls to `SemanticLogger::Base.thread_name` must be changed to `Thread.current.name`

### Fixed
- If :min_duration was not met exceptions were not being logged. Always log exceptions

## [2.4.0] - 2013-10-25
### Added
- Syslog appender
    - Send log messages directly to a local or remote Syslog server.
    - Supports local syslog and remote syslog over TCP or UDP.
    - Thanks to [Marc Bellingraths](https://github.com/marc).

### Changed
- Refactor colors used for each log level.

### Fixed
- Add ability to reopen the file appender after forking the process.

## [2.3.0] - 2013-09-23
### Added
- Add colorized logging.

### Fixed
- Exclude tags when the list is empty.

## [2.2.0] - 2013-08-02
### Fixed
- Fix tagged logging to work with Rails 4.

## [2.1.0] - 2013-04-03
### Changed
- Refactor interface to make it simpler to use in non-rails environments.
- Support replacing instance logger in Loggable mix-in.

## [2.0.0] - 2012-12-20
### Changed
- Remove Rails railtie and move to a separate gem: rails_semantic_logger.

### Fixed
- Handle condition where benchmark_info has no params.

## [1.0.0] - 2012-12-06
### Fixed
- Fix missing log entry when return is called inside the block.
- Fix "Errno::EBADF: Bad file descriptor - Bad file descriptor" on termination of the Ruby process.
- Handle scenario where "Appender thread has stopped" is being logged after Ruby has released file handles etc.
- Set log level for internal messages to the same as Rails.
- Workaround JRuby 1.8.6 under Trinidad with mode 1.9 startup and shutdown issues.
- Exclude gem files from built gem package.
- Help address a startup issue under JRuby with 1.9.

### Changed
- Move at_exit into global space.

## [0.11.0] - 2012-10-30
### Changed
- Rename module Attribute to Loggable.

## [0.10.0] - 2012-10-30
- Add SemanticLogger::Attribute mix-in to define class and instance variables for 'logger'.

### Changed
- Change exception description to exception message when exception is logged to Mongo collection.
- Add the level_index to Mongo Data so it can be searched on
    - Example: `level_index > 3`

## [0.9.0] - 2012-10-24
### Added
- Log queue depth when flushing appenders.

### Changed
- Move Appender base class behavior into it's own Base class
- Add guard to only flush if appender thread is still active

## [0.8.0] - 2012-10-19
### Added
- Remove shutdown ability/requirement since the Rails environment initializes multiple times causing repeated startup and shutdown issues.
    - The appender thread never stops and only flushes on termination now.
- Prevent messages from being queued up when no appenders have been defined.
    I.e. All logging overhead can now be entirely removed and only enabled when desired by adding an appender.

### Changed
- Replace using queuing for shutdown response with a Thread#join in case shutdown is called more than once.

## [0.7.0] - 2012-10-10
### Added
- Log time in microseconds on Ruby MRI.
- Add lag checking in case the appenders start falling behind.
- Add test to verify custom formatter.
- Support Ruby Logger Integer levels.
- Add parameters to benchmark_info etc. to control exception handling and min duration.

## [0.6.0] - 2012-09-18
### Added
- Replace Rails loggers if they are present.

### Fixed
- Use current thread object id as thread id when not using JRuby.
- Ignore existing Rails loggers since servers like Trinidad supply their own loggers
  which will result in duplicate log entries in the log file.

## [0.5.0] - 2012-09-11
### Added
- Log using the time the log was captured, not when it was written to the appender.
- File and STDOUT logging appenders.
    - Faster than going via the Ruby Logger.
- Railtie support for Rails 3 and now 3.2.
- Replace Rails Buffered Logger with SemanticLogger File Appender.

### Fixed
- Log duration in ms.

## [0.4.0] - 2012-09-05
### Added
- Support :trace log_level through Rails config.
- Add tags to Mongo document.
- Call flush only if recipient implements it.
- Remove trailing newlines.

### Removed
- Removed `SemanticLogger::Logger#flush` since Rails is flushing several times after completing a web request.
    - Use `SemanticLogger.flush` instead to flush all appenders.

### Changed
- Update docs

## [0.3.0] - 2012-08-21
### Added
- Add support for tags and payload hashes that are added to every log entry within the blocks
  scope and the current thread.

### Changed
- Initialize logger before the Rails one to prevent startup timing issues.

## [0.2.0] - 2012-08-20
### Changed
- Support restarts during tests.

## [0.1.0] - 2012-08-17
### Added
- Use Queue based logging with a separate appender thread.
- Ruby Logger Appender.
- MongoDB Appender.

