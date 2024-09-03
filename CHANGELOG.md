# Change Log

All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](http://semver.org/).

## [unreleased]

- Fix regression in `SemanticLogger::Appenders#close`

## [4.16.0]

- Add appender for Honeybadger Insights using the events API
- Add support for Ruby 3.3.
- Allow SyncProcessor to be called from appenders.
- Fix incorrect metrics usage examples in documentation.
- Add `:duration_ms` to Logfmt formatter.
- Fixes #216 Log message from supplied message argument when payload contains payload key.

## [4.15.0]

- Add support for Elasticsearch 7.x and 8.x in the Elasticsearch appender.

## [4.14.0]

- Add support for custom headers in HTTP appender.

## [4.13.0]

- Replace `autoload` with `require` for most requires since Ruby does not allow a require
  during a signal trap for the extreme use case where the logger is called from the signal
  trap before the application has made any logging calls.

- Move `newrelic_rpm.rb` mock to the `test/mocks` directory
- Add `add_mocks_to_load_path`
- Add NewRelicLogs formatter & appender

- Move initialization of `events` array in `CaptureLogEvents` to constructor.
- Add `clear` method to `CaptureLogEvents`.

- Add payload logging to `payload_includes` Minitest helper functionality.
- Fix bug in `payload_includes` testing functionality where if a key is not in the payload the test would pass.

- Quote 3.0 in CI configuration to prevent truncation.

- Add Minitest helper methods to assist with asserting logging events.

## [4.12.0]

- Add SyslogCee formatter for Syslog.
- The Logfmt formatter can now parse Hashes and Arrays correctly.
- Fixes a race condition in `SemanticLogger.reopen`.
- Ability to directly set proxy for `SemanticLogger::Appender::Http`
- Fixed log level signal handler to include fatal and error levels.
- Fixes #218 Calls Sentry.init inside sentry_ruby appender only if it is not initialized
- Contributor experience related to RuboCop was improved with the
  following changes:
    - New .rubocop\_todo.yml to hold RuboCop offenses and enable a clean
      run of RuboCop against the current code base.
    - A number of items in .rubocop.yml were removed to allow RuboCop to
      manage them within the .rubocop\_todo.yml file.
    - Updated RuboCop's target version to Ruby 2.7.5.
    - Updated minimum Ruby version to 2.7.5 as earlier versions are
      end-of-life.
- Add mutexes to `SemanticLogger.sync!` in case some users are still using it in a
  multi-threaded environment.

## [4.11.0]

- Add kafka client option to use system SSL settings: `ssl_ca_certs_from_system`
- Support rails tagged logger usage that yields itself:
~~~ruby
Rails.logger.tagged("tag") do |logger|
  logger.info("Hello World")
end
~~~
- Fixes #211 Stop modifying supplied hash.
- Fixes #194 Give message precedence over the message in the payload, if any.

- Passthru the ssl_ca_certs_from_system and required_acks flags to the ruby-kafka driver

## [4.10.0]

- New Feature: Add support for newer `sentry-ruby` gem.
- Fixed `flush` on `AsyncBatch` appender not immediately writing logs.

## [4.9.0]

- Separate out File and IO log appenders.
- Add "log rotation" like capabilities to the File appender.
  - Re-open the log file after a specified number of log entries.
    - See new SemanticLogger::Appender::File option `reopen_count`.
  - Re-open the log file after a specified number of bytes have been written by this process.
    - See new SemanticLogger::Appender::File option `reopen_size`.
  - New format directives so that file name dynamically includes any of the following attributes
    every time the log file is re-opened:
    - Host name
    - Process Id
    - Date
    - Time
    - See new SemanticLogger::Appender::File argument `file_name`.
- Add automatic retries for the file appender when an error occurs while writing to the file.
  - See new SemanticLogger::Appender::File option `retry_count`.
- Other options added to the file appender:
  - append, exclusive\_lock, encoding
- Documentation: Fix link to GitHub Actions CI configuration.
- Add support for logging to elastic data-streams
- Handle case when tags are passed as an array in a single argument to `SemanticLogger::Base#tagged`.
- feat: Add tags to logfmt formatter output
- fix: Ensure time\_key is used in logfmt formatter

Note: See the readme for v4.9 upgrade instructions.

## [4.8.2]

- Fixed method redefinition warnings when Rails is also used.
- Validate IO object can write when supplied to an IO appender.

## [4.8.1]

- Fixed issue where adding a file appender was being ignored after a console appender had already been added.

## [4.8.0]

### Changed

- Dropped support for Ruby 2.3 and 2.4.
- Moved testing to Github Actions.

### Fixed

- Allow `SemanticLogger.sync!` to be called after appenders have already been created.
- Refactor `SemanticLogger::Utils.extract_backtrace` for better backtraces in Rails Semantic Logger.

### Added

- Support for Ruby v3.
- New Logfmt formatter. #170
- Prevent multiple console (stdout or stderr) appenders from being added.

## [4.7.4]

### Fixed

- Allow Module filter to be passed in on the logger initializer #162

## [4.7.3]

### Fixed

- Remove `host` from the `SplunkHttp` appender message body.
- Support Bugsnag 6. Fix infinite loop. #150
- Fix documentation. #158

## [4.7.2]

### Changed
- Make Remote Syslog packet size configurable.

## [4.7.1]

### Fixed
- Fix an undefined method error when handling exceptions from on_log.
- Remove `environment` from the `SplunkHttp` appender message body.
- Replace Awesome Print with new supported fork called Amazing Print. #156
- Improve backward compatability. For example: `logger.message("Hello", duration: 20)`

## [4.7.0]
### Added
- SemanticLogger::Log.to_h
- Make it easier to remove the pid from logs #122
- Add Synchronous mode to perform logging in the current thread #137

## [4.6.1]
### Fixed
- Avoid leaking sensitive information when logging appender name
- Update docs to reflect minimum supported ruby v2.3
- Update docs to include DelayedJob in list of replaced loggers

## [4.6.0]
### Fixed
- Allow sending a metric with a message
- Fix graylog issue with non-exception logs

### Changed
- When a required gem is missing, raise a LoadError rather than a RuntimeError
- Appender#factory method signature
- Appender#build method signature
- SemanticLogger::Base.fast_tag no longer deprecated

### Removed
- Remove deprecated methods and backwards compatibility code:
  * AnsiColors::LEVEL_MAP
  * Appender::AnsiColors (use SemanticLogger::AnsiColors)
  * Appender.colorized_formatter (use SemanticLogger::Formatters::Color.new)
  * Appender.json_formatter (use SemanticLogger::Formatters::Json.new)
  * SemanticLogger::Base.payload (use SemanticLogger.named_tags)
  * SemanticLogger::Base.with_payload (use SemanticLogger.named_tagged)
  * SemanticLogger::Log.has_paylod? (use SemanticLogger::Log.payload?)
  * SemanticLogger::Log.formatted_time (use time.strftime(Formatters::Base.build_time_format))
  * SemanticLogger::Log.to_h (use Use SemanticLogger::Formatters::Raw)

### Added
- Log environment when available

## [4.5.0]

### Fixed
- Fix 'NameError' always raised and logged by Appenders#close
- SemanticLogger::Appender::Async segmentation fault
  Recreate Queue on #re-open
  Refactoring:
  * Create Appenders class
  * Move log subscribers to Logger class
- Error if payload does not respond to #size + Simple strings are shown twice
  Handle non-hash/payload as second argument by converting non-hash second argument to a string and appending to the message

### Added
- Date pattern support in Elasticsearch
- Support new Net::TCPClient in TCP Syslog appender

### Changed
- Use monotonic clock when measuring time
- Break out Appenders and Levels into separate files

### [4.4.0]

### Fixed
- Reopen child appender when using Async or Async Batch

### Added
- Add RabbitMQ appender
- Add Minitest Reporter to log test start and finish messages, as well as the duration of each test
- Fluentd formatter

### Changed
- Allow precision to be specified for formatters
- Allow a Module to define a filter

## [4.3.1]
### Fixed
- Fix Splunk HTTP Appender sourcetype -- @chroto
- Add back named tags as an instance method since it used in Rails apps -- @allcentury

## [4.3.0]
### Added
- Add option to allow an appender to log metrics only events.
  I.e. An event that contains a metric name, optional payload, but no message or exception.
  By default such events are not logged, except to the metric appenders.

### Fixed
- Reopen Syslog when already open -- @seanthingee
- Fix Sentry context attributes cannot be nil -- @joker-777

## [4.2.2]
### Fixed
- Fix Process Id not logging.

## [4.2.1]
### Added
- Add #push_named_tags and #pop_named_tags -- @aburgel
- Sentry appender can now define user context and tags context -- @joker-777

### Changed
- RuboCop Changes

### Fixed
- Fix Elasticsearch bulk bugs -- @wfxr
- Fix SemanticLogger.on_log -- @tsauerwein
- Fix exception typo for syslog -- @nbulaj

## [4.2.0]
### Added
- New Signalfx appender.
- New Async appender that puts any other appender in its own thread.
- New Batch appender to batch up groups of messages for appenders that support batching.
- API now supports metric dimensions.
- Support for metric only events. Does not require a log message to be created just to create a metric event.
- A new one line formatter. Strips stack traces and newlines in log messages.

### Changed
- Call `SemanticLogger.flush` instead of `SemanticLogger.close` on process exit.
- Elasticsearch appender now supports remaining Elasticsearch arguments. Thank you @willsoto.
- Documentation fixes. Thank you @Silex.
- Re-open http appender on failure.

### Fixed
- \#77 ArgumentError: wrong number of arguments. Now supports Hash only arguments when logging without needing a metric wrapper.
- Sentry Appender
  - \#69 undefined method `error_class` for the Sentry appender. Thank you @gingerlime.
  - Prevent feedback loops. Thank you @gingerlime.
  - \#74  NoMethodError: undefined method `host=' for #<Raven::Event:0x0000000d1621e8>. Thank you @gingerlime.

## [4.1.0]
### Added
- New log format customization mechanism.
  Any element within the log format can be replaced without having to re-implement entire formatter.
- Apache Kafka Appender.
- Prototype Syslog CEE format.
- `logger#tagged` now supports named tags. (Hash)

### Changed
- Elasticsearch now uses a bulk load api to improve throughput. Thank you [Xavier Lange](https://github.com/xrl)
- Replaced hash arguments with Ruby keyword arguments across all appenders and formatters.
- Removed deprecated arguments.
- Refactored Syslog appender and moved format code out of appender and into Syslog formatter.
- When the process exits `SemanticLogger.close` is now called instead of `SemanticLogger.flush`.
  Earlier test fameworks had issues where the `at_exit` was called and shutdown Semantic Logger
  before tests were run.

### Upgrade notes:
- As noted above deprecated arguments have been removed, so the following code, if any:
~~~ruby
SemanticLogger::Appender::File.new($stderr, :warn)
~~~

Needs to be replaced with keyword arguments:
~~~ruby
SemanticLogger::Appender::File.new(io: $stderr, level: :warn)
~~~

## [4.0.0]
### Added
- #backtrace to log the backtrace for a thread.
- `named_tags` to support hash like tagging of log messages.

### Changed
- Ruby V2.1 is now the minimum runtime version.
- Switch from Hash arguments to Ruby keyword arguments, for better performance, validation and defaults.
- Replaced Logger#with_payload with SemanticLogger.named_tagged.
- Replaced Logger#payload with SemanticLogger.named_tags.
- Any payload elements passed into the log line must now be specified in a separate :payload tag.
    - For example any occurrences of:
    ~~~ruby
    logger.error(message: 'Hello', response: response_message)
    ~~~

    - Must be changed to use the payload tag:

    ~~~ruby
    logger.error(message: 'Hello', payload: {response: response_message} )
    ~~~

    - Otherwise Ruby will raise the following error:

    ~~~
    ArgumentError: unknown keywords: response
    semantic_logger/lib/semantic_logger/log.rb:65:in `assign'
    ~~~

- For JSON and Hash appender format, payload is now in its own :payload tag instead of being merged into the hash.
- Text and Color formatters now include named_tags in their output.
- MongoDB Appender has been upgraded to support Mongo Ruby Client V2.
- Replaced hash arguments with keyword arguments.
  - For example, the Bugsnag Appender now only accepts the level as follows:
~~~ruby
SemanticLogger::Appender::Bugsnag.new(level: :info)
~~~

### Fixed
- Graylog appender when logger is called with only an exception object.
- During a backtrace dump, include the current thread on Ruby MRI.

### Dropped Support for
- Rails 3.2
- Ruby 1.9 & 2.0
- JRuby 1.7

## [3.4.1]
### Fixed
- Failed to load appender when symbolic name includes an underscore, for example:
~~~ruby
SemanticLogger.add_appender(appender: :new_relic)
~~~

## [3.4.0]
### Added
- Sentry Logging Appender.
- :metric_amount in JSON and Hash output.
- Add silence_logger for Active Record's Session Store.

## [3.3.0]
### Added
- Add Raw Formatter.
- Add standard application and host variables for all appenders.
- Add TCP log appender, with support for SSL connections.
- Add UDP log appender.

### Changed
- Consolidate formatter argument extraction.
- Log warning at 1,000 and info at 100 queued messages if logging appenders back up.
- SemanticLogger::Appender::Base is now SemanticLogger::Subscriber

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
        - `SemanticLogger.add_appender(file_name: 'development.log', formatter: :color)`
    - See [Appenders](https://logger.rocketjob.io/appenders.html)
    - Move AnsiColors into its own module: `SemanticLogger::AnsiColors`
- Appenders now use the same hash style arguments as `SemanticLogger.add_appender`.
- Appenders use the new common formatters where applicable.
- Appenders now use custom formatters as the `#call` method for better performance over blocks.
- Bugsnag appender will now forward `:fatal` errors, since some were being ignored and
  not being reported in Bugsnag. Changes in [Rails Semantic Logger](https://logger.rocketjob.io/rails.html)
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
- File and $stdout logging appenders.
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
