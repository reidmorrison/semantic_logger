# Change Log

All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](http://semver.org/).

## [Unreleased]

### Added

- The formatters that write a metric with its log entry also write the metric's `dimensions`:
  `:json`, `:raw`, `:fluentd`, `:ecs`, `:syslog_cee`, and `:new_relic_logs` as a `dimensions` Hash,
  `:loki` as a `dimensions` value in JSON, and `:open_telemetry` as a
  `semantic_logger.dimensions.<key>` attribute for each one. So do the appenders that use them,
  such as `:elasticsearch`, `:splunk_http`, and `:mongodb`. They are written only with a metric, as
  `Log#dimensions?` tells a custom formatter. See
  [Metrics in log appenders](https://logger.reidmorrison.com/metrics.html#metrics-in-log-appenders).
- Experimental: on Ruby 4.0 and later, code running in a Ractor other than the main one can log, and
  the main Ractor writes its entries to the appenders. Before, any log call from such a Ractor raised
  `Ractor::IsolationError`. See
  [Log from Ractors](https://logger.reidmorrison.com/api.html#log-from-ractors-experimental).
- `SemanticLogger.context` returns a frozen snapshot of the current tags, named tags, and silence
  level, and `SemanticLogger.with_context(context) { ... }` applies it in another thread or fiber,
  such as a thread pool's worker or an Async task. Tags belong to the fiber that set them, so these
  hand them over explicitly. See
  [Hand tags to another thread or fiber](https://logger.reidmorrison.com/api.html#hand-tags-to-another-thread-or-fiber).
- `SemanticLogger.backtrace_cleaner=` sets a backtrace cleaner, such as `Rails.backtrace_cleaner`,
  that leaves out or shortens the lines of each exception's backtrace, and of each exception that
  caused it, before they are logged. A cleaner is any object that responds to `#clean`, as
  `ActiveSupport::BacktraceCleaner` does, or to `#call`, such as a Proc. The text formatters
  (`:default`, `:color`, `:pattern`, `:syslog`) and the JSON formatters (`:json`, `:fluentd`) use
  it, and so do the appenders that use `:json` by default (`:http`, `:elasticsearch_http`, `:tcp`,
  `:udp`, `:kafka`, `:rabbitmq`, `:cloudwatch_logs`). The others, including `:raw` and the
  formatters written for a particular service, write the full backtrace, and appenders that send the
  exception to an error service are not affected. The new `backtrace_cleaner` formatter option
  chooses for one appender: `true` for the application's cleaner, `false` for the full backtrace,
  or a cleaner of its own. When a cleaner leaves out every line, or raises, the full backtrace is
  logged, and an error it raises is reported to the internal logger. Nothing changes until a
  cleaner is set. See
  [Cleaning backtraces](https://logger.reidmorrison.com/config.html#cleaning-backtraces).
- `Log#backtrace_of(exception, cleaner:)` returns an exception's backtrace as a cleaner cleans it,
  cached on the entry, and `Log#backtrace_to_s` accepts `cleaner:`, for custom formatters.
- `SemanticLogger.sensitive_keys=` names the keys, such as passwords and access tokens, whose values
  are replaced with `[FILTERED]` in every log entry before any appender writes it (discussion #272).
  It takes an Array of Symbols and Strings, which match any key whose name contains them, ignoring
  case, as in Rails' `config.filter_parameters`, and Regexps; or a Regexp; or an
  `ActiveSupport::ParameterFilter`, or any object that responds to `#filter_param`; or a Proc. Keys
  are matched by name, as written and in snake_case, so that `:_key` also matches `"X-Api-Key"`,
  `"apiKey"`, and `"APIKey"`. The payload, named tags, the context that `on_log` subscribers add,
  and metric dimensions are redacted at any depth, inside Hashes, Arrays, Sets, Structs, Data,
  OpenStructs, and `ActionController::Parameters`, once per entry on the thread that writes the
  entries, so every appender, including error services and appenders of your own, writes the
  redacted entry. The application's own Hashes are never changed, and an entry with no sensitive key
  is written as it is, unless it holds a structure that holds itself or is nested more than 32
  levels deep. When an entry cannot be redacted, the field is replaced with
  `{redaction_failed: "ErrorClass"}` and the error is reported to the internal logger. The message,
  tags, and exception are not redacted, and `on_log` subscribers and logger filters receive the
  entry as it was logged. Nothing changes until sensitive keys are set. See
  [Redacting sensitive data](https://logger.reidmorrison.com/security.html#redacting-sensitive-data).
- `SemanticLogger.call_site_level=` records where each entry at or above that level was logged: the
  file, line, and method of the code that made the log call, in `Log#call_site`. Unlike
  `backtrace_level` it reads only the stack frames up to that code, so it adds about 1.5 µs to a log
  call however deep the stack is, where a backtrace adds 16 µs or more. It is off (`nil`) by default.
  With it on, the text formatters show the method after the file name and line number, `:json` and
  the other formatters built on `:raw` add a `method` field, `:pattern` has a `%{method}` directive,
  `:ecs` writes `log.origin.function`, `:new_relic_logs` writes `method.name`, and `:open_telemetry`
  writes `code.function.name`. When a log call supplies a `backtrace:`, its first line is the call
  site. `SemanticLogger.call_site_skip_paths=` skips the frames of an application's own logging
  helpers, so that entries record the code that called them. See
  [Recording where each entry was logged](https://logger.reidmorrison.com/config.html#recording-where-each-entry-was-logged).
  Resolves discussion #219.
- A log call, or a `measure_*` call, can pass `call_site:` to say where the entry was logged, as a
  `Thread::Backtrace::Location` or a `SemanticLogger::CallSite`, or `call_site: false` for an entry
  with no such code, which records none without reading the stack for it. For code that logs on
  behalf of other code, such as a log subscriber. It is only recorded at or above `call_site_level`.
  See
  [Recording where each entry was logged](https://logger.reidmorrison.com/config.html#recording-where-each-entry-was-logged).
- A custom appender whose `#batch` is all or nothing can now say, from the new
  `#fails_any_batch?(exception)`, that a message error would fail any batch, whatever it holds, such
  as a request refused for its credentials. A batch that fails with such an error is then discarded at
  once, rather than split up and each part written again to find the entries at fault. It returns
  `false` by default, so that every batch is split as before. See
  [Custom appenders](https://logger.reidmorrison.com/config.html#custom-appenders).
- The `:loki` formatter's `structured_metadata:` option writes the process id, the thread name, or
  both, as the structured metadata `pid` and `thread`, instead of as stream labels, so that a
  process restart or a new thread no longer adds a Loki stream. A query can still filter on them,
  as in `{application="shop"} | thread="worker-1"`. A payload key of that name is then written as
  `payload_pid` or `payload_thread`, and a named tag or context key as the label `pid_2` or
  `thread_2`. It needs a Loki that accepts structured metadata, with schema v13 and
  `allow_structured_metadata`, on by default since Loki 3.0. Set it with
  `add_appender(appender: :loki, formatter: {loki: {structured_metadata: [:pid, :thread]}}, ...)`.
  The default is still to write them as labels; v6 changes it (see Deprecated). See
  [pid and thread as structured metadata](https://logger.reidmorrison.com/appenders.html#pid-and-thread-as-structured-metadata).

### Changed

- A deprecation warning now names the line of the application that used what is deprecated, such as
  where it added a deprecated appender, and starts with `SemanticLogger: `, as in
  `config/initializers/logging.rb:12: warning: SemanticLogger: ...`. Before, it named no line. As
  before, Ruby only shows it while `Warning[:deprecated]` is true. See
  [Seeing deprecation warnings](https://logger.reidmorrison.com/upgrading.html#seeing-deprecation-warnings).
- The `:open_telemetry` appender no longer sends metric-only entries, which have a metric but no
  message and no exception, by default. It sent each one as a log record with no body, never as an
  OpenTelemetry metric; they are meant for the metric subscribers. Add the appender with
  `metrics: true` to keep sending them. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- The `:statsd` and `:new_relic` metric subscribers record a metric that has `dimensions` under its
  name alone, leaving out the dimensions, which neither the `statsd-ruby` client nor the New Relic
  agent's metric API accepts. Before, they left such a metric out altogether. The `:statsd`
  subscriber now also takes the options of every subscriber, such as `level:` and `filter:`, as the
  other metric subscribers do. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- The `#logger` of an appender added with `logger:` or `appender: :open_telemetry` returns its
  internal logger, the one it reports its own problems to, as for every other appender, and
  `#logger=` replaces that internal logger. Before, they returned and replaced the logger that the
  appender writes to; a `logger:` appender's is now `#wrapped_logger`. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- `log_exception: :partial`, the default for `measure_*` blocks, now also adds each exception that
  caused the logged one to the message, as ` -- Cause: Class: message`, so that it names the same
  exceptions as `log_exception: :full`. A cause's message is left out when it is empty, is its class
  name, or is already in the message, as when the exception that wraps it copied it into its own:
  `-- Exception: ActionDispatch::Http::MimeNegotiation::InvalidType: "foo/bar" is not a valid MIME
  type -- Cause: Mime::Type::InvalidMimeType`. Before, the causes were left out. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- The `:http` appender, and the appenders derived from it, such as `:loki`, `:splunk_http`,
  `:elasticsearch_http`, and `metric: :signalfx`, close their connection when they are closed, such
  as when removed with `SemanticLogger.remove_appender`, or by `SemanticLogger.close`. Before, it was
  left open. One that is added again opens a new connection for its next request, and keeps it for
  the requests that follow.
- `SemanticLogger.remove_appender` waits, as `SemanticLogger.flush` does, until the log messages
  already logged are written to the other appenders, and those are flushed, before it closes the
  appender. Before, it closed the appender at once, while the processor could still be writing a
  message to it, such as on the socket of a `:tcp` appender, or the connection of an `:http`
  appender, which could then open a new connection that was left open. Called on the processor's own
  thread, such as by an appender as it writes, it still closes the appender at once.

- `Log#each_exception` accepts the exception to start from, for custom formatters and appenders that
  walk the causes of an exception the entry does not keep.

- A `call_site` key of a logged Hash is now the `call_site:` argument when its value is `false`, a
  `Thread::Backtrace::Location`, or a well-formed `SemanticLogger::CallSite`, and is no longer logged
  in the payload. A `nil` value counts as not supplied, as for the other arguments, and is not logged
  either. Other values, such as a String, are still logged in the payload.

- `SemanticLogger.host=`, `application=`, and `environment=` store a frozen copy of the value
  supplied, so that code in a Ractor can read it, and the default host name is frozen too.
  The value supplied is left as it is.

- The `:open_telemetry` appender sends the message as the body of each log record, as documented,
  instead of a map of the whole log entry. The named tags become attributes of their own alongside
  the payload, and the entry's own fields become attributes: the exception as `exception.type`,
  `exception.message`, and `exception.stacktrace`, the file and line as `code.file.path` and
  `code.line.number`, plus `thread.name`, `process.pid`, `semantic_logger.name`,
  `semantic_logger.tags`, `semantic_logger.duration_ms`, `semantic_logger.metric`, and
  `semantic_logger.metric_amount`. The host, application, and environment are no longer sent, since
  OpenTelemetry reports them in its resource (`OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`).
  The formatter now returns the keyword arguments for the OpenTelemetry `Logger#on_emit`, so a
  custom formatter for this appender must do the same. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html). Resolves #428.

- The `:elasticsearch` and `:opensearch` appenders send again the entries of a bulk request that the
  server rejected with status 429 because its write queue was full, which are likely to be indexed a
  little later. Before, they were reported to the internal logger and discarded with the entries that
  failed for any other reason. Only those entries are sent again, so that none is indexed twice, up to
  3 times, after waiting 0.2, 0.4, then 0.8 seconds. That holds up the thread that writes the entries
  for waits of at most 1.4 seconds for a request, plus up to 3 more bulk requests. The entries still
  not indexed are reported and discarded, as before. See
  [Elasticsearch](https://logger.reidmorrison.com/appenders.html#elasticsearch) and the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- An appender added with `async: true` or in batches sends an entry or batch that its destination
  could not take again once it has backed off, rather than discarding it, when the appender says that
  the write wrote nothing and is worth trying again. Once the destination has answered it with a
  failure after it was sent again 3 times, it is discarded, and the thread carries on with the next
  one; a write that never reached the destination, such as one that could not connect, is not
  counted, so an outage loses no entries until the thread gives up after `async_max_retries`. The
  `:http`, `:elasticsearch_http`, `:splunk_http`, and `:loki` appenders, and the `:signalfx` metric
  subscriber, say so for a 408, 429, or 503, such as a 503 while Loki restarts, and for a request
  they could not send because they could not connect. A 500, 502, or 504, and a request that failed
  once it was sent, such as one whose answer timed out, are still discarded. A custom appender says
  so from the new `#wrote_nothing?(exception)`, and that the write never reached the destination
  from `#not_sent?(exception)`, both of which return `false` by default.
  A flush or close, including the flush at exit, no longer waits out the back-offs during an outage:
  submitting one ends the back-off under way, and until it has run, an entry or batch that fails is
  discarded, counted as `failed`, without backing off, and so are the entries queued after it, ahead
  of the flush or close (see below). Before, a flush with 5 entries queued during an outage waited
  1 + 2 + 3 + 4 + 5 seconds. See
  [Retry a failing appender](https://logger.reidmorrison.com/operations.html#retry-a-failing-appender)
  and the [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- During an outage of the destination of an appender added with `async: true` or in batches, the
  process exits within seconds, rather than hours. A flush or close, including the flush at exit,
  now discards the entries queued ahead of it once a write fails because of the destination, counted
  as `failed`, rather than send each one in turn, which against a server that does not answer took
  up to its `open_timeout` each. At exit, each such appender is also told that the process is
  exiting before the flush, directly rather than through the main queue, so that it stops backing off
  and sending again what failed even while the thread that writes to every appender is held up
  handing it an entry. A destination that takes the entries still gets every one of them. See
  [Retry a failing appender](https://logger.reidmorrison.com/operations.html#retry-a-failing-appender)
  and the [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).

### Deprecated

- Building the `:loki` formatter without `structured_metadata:`, as adding the `:loki` appender does
  unless it is given `formatter: {loki: {structured_metadata: ...}}`. It still writes `pid` and
  `thread` as stream labels, but v6 writes them as structured metadata by default, so it now reports
  a deprecation warning. Pass `structured_metadata: []` to keep them as labels, or
  `structured_metadata: [:pid, :thread]` to write them as structured metadata. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- Adding the `:kafka`, `:rabbitmq`, or `:udp` appender without `metrics:`. They still send
  metric-only entries by default, which have a metric but no message and no exception, but v6 leaves
  them out by default, as the other log appenders do, so they now report a deprecation warning. Pass
  `metrics: true` to keep sending them, or `metrics: false` to leave them out. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- Giving `add_appender` a formatter block, or the options of an appender, such as `level:`,
  `formatter:`, or `filter:`, with an appender or metric subscriber instance, such as
  `add_appender(appender: my_appender, level: :warn)`. The instance was created with its own options,
  so they were ignored without a word. They still are, but `add_appender` now reports a deprecation
  warning that names them, and v6 raises `ArgumentError` for them. Set them on the instance itself.
  An option given as `nil` sets nothing, and is not reported. The options of `add_appender` itself,
  such as `async:` and `batch:`, still apply to an instance. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- Giving `add_appender` more than one destination, such as
  `add_appender(file_name: "log/app.log", io: $stdout)`. It added only the first of `file_name:`,
  `io:`, `logger:`, `appender:`, and `metric:`, and ignored the others without a word, so nothing
  was written to `$stdout`. It still does, but now reports a deprecation warning that names the
  destination it uses and those it ignores, and v6 raises `ArgumentError` for them. Call
  `add_appender` once for each destination. A destination given as `nil` is not reported. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).

### Removed

- `logger_measure_method`, an experiment that `SemanticLogger::Loggable` added to each class, and
  that was never part of the documented API. To log how long a method takes, wrap its body in a
  `measure_*` block, and pass `metric:` to keep the metric it logged, such as
  `logger.measure_info("#run", metric: "MyClass/run") { ... }`. To trace it, use OpenTelemetry's
  `tracer.in_span`, or the method tracer of an APM agent. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).

### Fixed

- `add_appender` raises `ArgumentError` when it would batch an appender whose formatter cannot
  format a batch, such as a formatter block given to `:http`, `:loki`, or `metric: :signalfx` with
  `batch: true`, and says what to do instead. Before, it added the appender, but every batch failed
  on the appender's worker thread, which backed off and tried again, so nothing was ever written,
  and once its queue was full, logging blocked, unless it was added with `non_blocking: true`. The
  error names the formatter. A custom appender whose `#batch` formats each entry with `format_log`
  is batched with any formatter, as before, and one that cannot be batched in some configuration can
  say why from `#batch_refusal`. When `add_appender` fails after creating the appender, such as for
  one that it cannot batch, it closes the appender. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- `add_appender(appender: :elasticsearch_http, batch: true)` raises `ArgumentError`, and says to use
  the `:elasticsearch` appender, which sends its entries in bulk requests, to send them in batches.
  Before, it posted each batch as a JSON array to the url's own path, such as `/`, which
  Elasticsearch rejects, since it indexes a batch only through its bulk API, so nothing was ever
  indexed. A custom appender can refuse to be batched in the same way, with a reason of its own, by
  returning it from `#batch_refusal`. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- The `:statsd` metric subscriber records metrics as soon as it is added. Before, it created its
  Statsd client only when reopened, such as after a fork, so in a process that did not fork, such as
  a single Puma or Sidekiq process, every metric failed with `NoMethodError` and was reported to the
  internal logger instead. A `url:` that is not `udp://`, or whose host cannot be resolved, now raises
  as the subscriber is added, as for the `:udp` appender, and an IPv6 address such as
  `udp://[::1]:8125` is now accepted. Reopening it, such as after a fork, now reconnects its client,
  which closes the socket the client had, instead of leaving it open, and leaves the client as it
  was when the host cannot be resolved.
- `add_appender(metric: ...)` with a value that is neither a Symbol nor a `SemanticLogger::Subscriber`
  now names that value in its `ArgumentError`. Before, the message named the `appender:` option
  in its place, usually as `not: nil`.
- A block given to `add_appender` formats the entries of an appender or metric subscriber named by a
  Symbol, such as `add_appender(appender: :tcp, server: "localhost:514") { |log| log.message }`, as
  it does for `io:`, `file_name:`, and `logger:`, taking precedence over `formatter:`. Before, the
  block was ignored, and the appender used its `formatter:` or its default formatter.
- The `:elasticsearch` and `:opensearch` appenders accept `metrics: true`, to also index metric-only
  entries: a metric without a message or an exception. Before, `metrics:` was passed on to the
  Elasticsearch or OpenSearch client, and those appenders always left metric-only entries out.
- The `measure_*` and `benchmark_*` methods, and `measure` and `benchmark`, keep a `dimensions:`
  option, such as `metric: "supplier/add_user", dimensions: {supplier: "acme"}`, with a block or
  with `duration:`. Before, the entry had no dimensions, so the `:signalfx` metric subscriber could
  not break the metric down by them, and the structured formatters did not write them. A
  `dimensions:` value that is not a Hash is ignored, as the other measure options ignore a value
  that is not valid for them. SignalFx now sends such a metric under its own name, as it sends any
  metric with dimensions, instead of as `Application.average` and `Application.counter`, and
  without the named tags listed in its own `dimensions:` option, which it only adds to a metric
  without dimensions, so put those values in the metric's `dimensions:`. SignalFx also treats empty
  dimensions, such as `dimensions: {}` or `{supplier: nil}.compact`, as none, as `Log#dimensions?`
  does, on a log call too. Before, a metric logged with them was sent under its own name, and a
  duration without a count, without the `class` and `action` taken from its name, or the named tags
  listed in the subscriber's `dimensions:` option. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- The `:loki` formatter writes a metric's `metric_value` as a String, such as `"3"`, and leaves it out
  for a metric without an amount. Loki accepts only Strings in structured metadata, and rejected the
  whole push with `400 Bad Request` for a number or `null`, so every entry with a metric was lost,
  and with `batch: true` so was every other entry in its batch. The appender reported each
  rejection to the internal logger. The `metric_value` and the `duration` are written as LogQL reads
  numbers, to compare or `unwrap` them: an Integer as it is, and any other number as a decimal, such
  as `"1.5"`. A Rational `duration` was written as `5/2`, which made every query that unwrapped it
  fail. The `exception_name` of an exception whose class is anonymous, and the `exception_message`
  of one whose `#message` returns nil, which were `null` too, are now Strings: the name as the text
  formatters write it, such as `#<Class:0x000...>`, and an empty message.
- The `:loki` formatter writes a payload key named like one of its own structured metadata fields,
  `metric`, `metric_value`, `dimensions`, `duration`, `duration_human`, `exception_name`,
  `exception_message`, or `stack_trace`, with a `payload_` prefix, as in `payload_duration`, as
  `:logfmt` and `:open_telemetry` prefix theirs with `payload.`. It wrote the payload's value and its
  own under the same name, and Loki keeps only the last, so the payload's value was lost. A payload
  key that Loki stores under one of those names, such as `metric.value`, `metric__value`, or one
  with an invisible character, replaced the formatter's value instead, so that a query that
  `unwrap`s `metric_value` failed. The key is prefixed whether or not the entry has that field, so
  that each of these names always holds the formatter's value. It is written under the name Loki
  stores it as, such as `payload_metric_value` for `metric.value`, and with the prefix again when
  another payload key has that name once Loki has stored it, as in `payload_payload_metric_value`,
  so that Loki keeps the value of each prefixed key. A key that is exactly one of these names gets
  the name with one prefix, whatever the order of the keys. See
  [Upgrading to v5.3](https://logger.reidmorrison.com/upgrading.html#upgrading-to-semantic-logger-v53)
  and [Grafana Loki](https://logger.reidmorrison.com/appenders.html#grafana-loki).
- The `:loki` formatter no longer loses an entry, with every other entry pushed with it, for a named
  tag or context key that Loki does not accept as a label name, such as `request-id`, `1st`, or an
  empty key, or for a payload key without an ASCII letter or digit, such as an empty key, `-`, or
  the `_` that jQuery adds to the parameters of a request it keeps from being cached. Loki rejected
  the push with `400 Bad Request` ("couldn't parse labels") or `500` ("label name is empty"). Such a
  label name is now written as Loki writes the names of structured metadata: each run of characters
  other than ASCII letters and digits replaced with one `_`, and `key_` before a name that would
  start with a digit, or is empty. So `request-id` is written as `request_id`, and `1st` as
  `key_1st`. When another label already has that name with another value, as Loki stores it, a
  number is added, as in `request_id_2`, so that both are kept. Such a payload key is written with the `payload_` prefix, as
  Loki stores it, so an empty key as `payload_`, and with the prefix again when another key has that
  name, so that Loki keeps the value of each. A named tag that is nil, and a nil host, are left out,
  instead of being written as the label `null`.
- The `:loki` formatter keeps both values of a named tag or context key that has the name of another
  label. Loki keeps one value of a label, so a named tag such as `host`, `level`, or `pid` replaced
  the formatter's own label, and an `:info` entry tagged `level: "warn"` was stored as `level="warn"`.
  A context key replaced a named tag of the same name, and so did a named tag given both as a Symbol
  and as a String. Now the formatter's own labels, the named tags, and the context are written under
  their own names, in that order, then each one whose name Loki does not accept under the name that
  replaces it, when no label has that name yet, and then each of the rest, with the first number
  added that no other label has, as in `host_2`, so that the number is never another label's name,
  whatever the order of the keys. It is written once when the label of that name, or of a numbered
  name before it, has the same value, as Loki stores it. The stream's label names are now Strings,
  so a subclass of the formatter that reads, replaces, or deletes a label in `stream[:stream]` uses a
  String key, such as `"host"`. A label that a subclass writes under a Symbol, as v5.2 did, is
  written under its name as a String, numbered when a label written before it has that name. See
  [Upgrading to v5.3](https://logger.reidmorrison.com/upgrading.html#upgrading-to-semantic-logger-v53)
  and [Grafana Loki](https://logger.reidmorrison.com/appenders.html#grafana-loki).
- The `:loki` formatter no longer loses an entry, with every other entry pushed with it, for a stream
  with more than 15 labels, such as an entry with ten named tags, a label name longer than 1024
  bytes, or a label value longer than 2048 bytes, such as many tags. Loki rejected the push with
  `400 Bad Request`. Such a label is now written to the structured metadata instead, as a String,
  where a query can still filter on it: the labels after the 15th in the order the formatter writes
  them (its own, then the named tags and the context under their own names, then those whose names
  were taken or replaced), and any label with a longer name or value.
  The new formatter options `max_label_names_per_series`, `max_label_name_length`, and
  `max_label_value_length` set these limits for a Loki that raises them, as in
  `formatter: {loki: {max_label_names_per_series: 30}}`. See
  [Loki's label limits](https://logger.reidmorrison.com/appenders.html#lokis-label-limits).
- The `:open_telemetry` appender, and an appender added with `logger:`, work with `async: true`.
  Before, the worker thread stopped as it started, with `NoMethodError` (undefined method 'trace'),
  so the appender wrote nothing, and unless it was added with `non_blocking: true`, every log call
  blocked once its queue was full. With a `logger:` that has a `trace` method, the worker thread
  wrote its own messages to that logger instead. Their `#logger` returned the logger they write to,
  rather than the internal logger that every appender reports its own problems to, which the worker
  thread uses; it now returns the internal logger (see Changed). The `:open_telemetry` appender also
  reports a failure to flush or shut down to its internal logger, as the other appenders do, rather
  than to `SemanticLogger::Processor.logger`, so that the report names the appender. The worker
  thread of any appender run with `async: true` or in batches now also keeps running when the
  appender's internal logger cannot take the thread's own messages, such as a Ruby Logger returned
  by a custom appender's own `#logger`, which has no `trace` method and takes no exception. Such a
  logger now gets each of those reports that it can take, with the exception, if there is one, added
  to the message. Before, it got none of the reports with an exception, such as a discarded message,
  a restart, or the thread stopping. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- `SemanticLogger.reopen(force: true)` in a process that has not forked, such as after a log
  rotation, no longer loses track of the thread that writes the log entries, or of the thread of
  an appender added with `async: true` or in batches. Before, the thread it replaced, as it ended,
  cleared the new one, so that `SemanticLogger.flush` returned `false` without waiting for the
  queued entries, and entries still queued at exit could be lost.
- The `:kafka` appender keeps its `required_acks:` after it is flushed, such as with
  `SemanticLogger.flush`. Before, a flush replaced the appender's producer with one built without
  it, so ruby-kafka's default of `:all`, which waits for every in-sync replica to acknowledge each
  delivery, replaced the appender's default of `1`, or the value given.
- The `LoadError` raised when the `:kafka` appender is added without the `ruby-kafka` gem names
  Kafka. It said that the gem is required for logging to Elasticsearch.
- Reopening the `:kafka` appender in the same process, such as with
  `SemanticLogger.reopen(force: true)`, no longer leaves the producer it replaces running, with its
  two threads, and its connections open. The next time the appender logs, it starts a thread that
  shuts that producer down, which delivers the entries it still holds, and closes its client.
  Flushing or closing the appender waits for that thread, or shuts the producer down itself.
  Neither reopening nor logging waits for the delivery, so that reopening still works in a signal
  trap, where ruby-kafka cannot shut down a producer, and the thread that writes to every appender
  does not stop while Kafka cannot be reached. Since the new producer delivers meanwhile, the
  entries of the one it replaced can reach Kafka after newer ones. An error shutting that producer
  down is reported to the internal logger, rather than raised. After a fork, the child still leaves
  the producer and client it inherited alone, since shutting them down there would send the
  parent's undelivered entries a second time, over the parent's own connections. When the appender
  cannot build a new producer, such as after setting a negative `delivery_threshold`, flushing it
  now keeps the producer it has, which still delivers, rather than the one it had just shut down,
  and reopening it in the same process keeps both its client and producer. In a forked child it
  then has none, and logging to it raises `IOError` until a reopen builds one. Flushing the appender
  after closing it no longer raises `NoMethodError`, and logging to it raises `IOError` instead.
- The `:udp` appender sends to an IPv6 address written in brackets, as a URL writes it, such as
  `server: "[::1]:8088"`. Before, it split the server at every colon, and its socket was IPv4 only,
  so it could not be given an IPv6 address. A host name with an IPv4 address still uses it. A
  `server:` that is not `"host:port"`, such as one without a port, or an IPv6 address without
  brackets, now raises `ArgumentError`, which names the form to use, as the appender is added.
  Before, a missing port was taken as port 0.
- When the `:udp` appender is reopened, such as after a fork, and cannot connect to its server, such
  as for a host name that no longer resolves, it keeps the socket it had, which still sends to the
  address it connected to. It raises the error as before, which `SemanticLogger.reopen` reports to
  the internal logger. Before, it closed that socket first, and kept a new one that was not
  connected, so every entry after it failed with `Errno::EDESTADDRREQ` until the next reopen.
- The `:udp` appender sends to a host name that has only IPv6 addresses, over IPv6. Before, its
  socket was IPv4 only, so adding it raised `SocketError`, since the name has no IPv4 address. A
  name with both is still sent to over IPv4, whichever address the resolver returns first, unless
  it cannot connect over IPv4, such as on a host with no IPv4 route, when it now uses IPv6 instead
  of raising. It looks up a name's IPv6 addresses only when the resolver answers that the name has
  no IPv4 address, or when it cannot connect to any of them, so that a resolver that does not answer
  for them does not delay it otherwise. When looking up the IPv4 addresses fails for another reason,
  such as a resolver that does not answer in time, it raises that `SocketError` at once, as before,
  rather than sending over IPv6 to a name that may have IPv4 addresses. On Ruby 3.2 and JRuby, whose
  `SocketError` does not say why a lookup failed, it looks up the IPv6 addresses after any failure.
  When it cannot connect to any address, it raises the error from the first one it tried, an IPv4
  address when the name has one. A name that does not resolve raises `SocketError` as before.
- `log_exception: :partial`, the default for `measure_*` blocks, no longer raises
  `Encoding::CompatibilityError` when the log message and the exception's message are in
  incompatible encodings, such as a UTF-8 message with accented letters and a binary exception message
  that holds bytes outside ASCII. Before, the log call raised, and a `measure_*` block raised that
  error in place of its own exception. Now, when joining the message, the exception's class name, and
  its message would raise, or would make an ASCII message binary, they are converted to valid UTF-8
  first: binary text is read as the UTF-8 it usually holds, and invalid bytes are dropped. Text in
  another encoding, such as ISO-8859-1, otherwise stays in it.
- A log call no longer raises `Encoding::CompatibilityError` when the String that a block returns is
  in an encoding incompatible with the message, such as `logger.info("Café") { response.body }`
  with a binary body that holds bytes outside ASCII, or when the second argument is such a String,
  as in `logger.info("Café", response.body)`. Before, the error was raised into the application.
  Now they are joined the way `log_exception: :partial` joins the message and the exception's
  message. So a binary String added to an ASCII message is now read as UTF-8 too, and the message
  stays UTF-8, without the String's bytes that are not valid UTF-8, rather than becoming binary.
- `:default`, `:color`, and `:pattern` without `escape_control_chars`, and `:syslog` with
  `escape_control_chars: false`, no longer lose an entry whose texts are in incompatible encodings,
  such as a UTF-8 message logged with an exception whose message is binary and holds bytes outside
  ASCII, a binary message after a logger name with accented letters, the text of tags or named tags
  in different encodings, or the binary message of an exception that caused the logged one. A UTF-16
  message no longer loses the entry either, and neither does such a cause in the stack trace that
  `:loki` and `:open_telemetry` write. Before, formatting raised `Encoding::CompatibilityError`, and
  the appender reported the error to the internal logger instead of writing the entry. Now a String
  that holds bytes outside ASCII in an encoding other than UTF-8 is converted to UTF-8 before it is
  written, as `:one_line`, `:syslog` with its default escaping, and `escape_control_chars: true`
  already do: binary text is read as the UTF-8 it usually holds, and its invalid bytes are dropped,
  and text in another encoding, such as ISO-8859-1, is converted. So these formatters now always
  write UTF-8, also for an entry whose text is all in one other encoding, which they used to write
  in that encoding. A `:pattern` or `time_format` in another encoding is converted to UTF-8 when the
  formatter is built, and the host, application, and environment names that `:pattern` writes are
  converted too, such as an application name read from the environment where no locale is set.
  See [Upgrading to v5.3](https://logger.reidmorrison.com/upgrading.html#upgrading-to-semantic-logger-v53).
- `:one_line` now also removes the Unicode next line (U+0085), line separator (U+2028), and
  paragraph separator (U+2029) from every text field, or escapes them as `\u0085`, `\u2028`, and
  `\u2029` with `escape_control_chars: true`. Editors, browsers, and some log viewers start a new
  line at each, so logged text that held one, such as a user's input, could show an entry over
  two lines. Exception details are also split into lines at them, and joined with a space.
- With json 2.8.0 through 3.0.x, logging a binary String that holds UTF-8, such as a response body,
  in a payload, tag, named tag, or exception message no longer prints "warning: JSON.generate:
  UTF-8 string passed as BINARY, this will raise an encoding error in json 3.0" to standard error,
  once for each such String every time a JSON based formatter or `:logfmt` writes the entry,
  including in the appenders that use them, and `:graylog`. The JSON is unchanged: the String is
  written as UTF-8, as it is with json 3.1. On those json versions Semantic Logger prepends a
  module to Ruby's `Warning` that drops that one warning when it comes from serializing log data;
  the application's own JSON, including an exception's own `#message`, still warns. `:graylog` now
  hands the gelf gem a copy with such Strings converted to UTF-8, since the gem serializes it
  itself, and so does `:sentry_ruby`.
- A `measure_*` block that raises an exception whose `#message` raises, such as one that reads a
  record that is nil, now re-raises its own exception. Before, with `log_exception: :partial` (the
  default), the error that `#message` raised replaced it, without it as the cause, and nothing was
  logged; a log call with `log_exception: :partial` raised that error too. Now `:partial` writes the
  message the exception was raised with instead, or its class name when it was raised without one,
  as in `Saving -- Exception: OrderError: OrderError`, and does the same for each exception that
  caused it.
- The JSON based formatters (`:json`, `:raw`, `:fluentd`, `:ecs`, `:loki`, ...), `:logfmt`,
  `:one_line`, `:open_telemetry`, `:syslog`, the other text formatters with
  `escape_control_chars: true`, and `:cloudwatch_logs` no longer drop the characters of a binary
  String that holds UTF-8, such as a response body, Base64-decoded text, or a C extension's error
  message, or of a US-ASCII String that holds UTF-8, such as a file read or an environment variable
  where no locale is set. Before, every byte outside ASCII was dropped, valid UTF-8 or not, so
  `"Café ☕".b` was written as `"Caf "`. On every json gem version this happened to the message, and
  to the text that `:open_telemetry` writes or that a formatter escapes; since json 3.1, which no
  longer writes a binary String as UTF-8, it also happened to payload values and keys, tags, named
  tags, and exception messages in the JSON based formatters. Now such text is read as UTF-8, and
  only its invalid bytes are dropped. A binary key name that holds UTF-8, such as `"contraseña"`, now
  also matches `SemanticLogger.sensitive_keys`.
- The JSON based formatters (`:json`, `:fluentd`, `:ecs`, `:loki`, `:syslog_cee`, ...) no longer
  drop an entry whose payload or named tags hold a Symbol named in an encoding other than UTF-8 that
  holds bytes outside ASCII, such as the binary key of a request turned into a Symbol. With json 3.1
  that included a binary Symbol that holds valid UTF-8, and on CRuby with earlier versions a Symbol
  with invalid bytes, and from json 2.9 one with UTF-8 bytes tagged US-ASCII. Before, formatting
  raised `JSON::GeneratorError`, and the appender reported the error to the internal logger instead
  of writing the entry. Now the name of such a Symbol is converted to valid UTF-8, as a String is, so
  `"Café".b.to_sym` is written as `"Café"`. `:graylog` now also hands the gelf gem such a Symbol
  converted, so that the gem neither raises nor prints the json gem's warning about it.
- When an async or batching appender's destination fails, the message (or batch) being written is
  now counted as `failed` in `SemanticLogger.stats` and reported to the internal logger, as a message
  whose content cannot be written already was. Before, it was discarded without being counted, and
  the docs said it was retried. Delivery is unchanged: the worker thread backs off, then carries on
  with the messages queued meanwhile. See
  [Retry a failing appender](https://logger.reidmorrison.com/operations.html#retry-a-failing-appender).
- The test helpers now call each `on_log` subscriber once per log event. Before, they called it twice
  when capturing the events of every class: with `semantic_logger_events` or
  `capture_semantic_logger_events` without a class, or with a `SemanticLogger::Test::CaptureLogEvents`
  that replaces the processor or is added as an appender.
- The custom appender example in the configuration guide now runs. Its `host: host` option default
  is a syntax error on Ruby 3.2 and 3.3 and is `nil` on later versions, and `host` is already an
  option of every appender, so the example's value was overwritten. The example now takes a
  required `url:` option. See [Custom appenders](https://logger.reidmorrison.com/config.html#custom-appenders).
- The formatter of an appender added with `async: true` (or batching) can be read and changed with
  `formatter` and `formatter=`, as for any other appender. Before, these raised `NoMethodError`.
  An appender that formats its messages as one batch needs a formatter that implements `#batch`. See
  [Changing an appender while running](https://logger.reidmorrison.com/config.html#changing-an-appender-while-running).
- Setting `formatter=` on a TCP or UDP syslog appender to `:syslog` or `:syslog_cee` keeps the
  appender's facility, level map, and maximum packet size, as passing `formatter:` when adding it
  already did. Before, the new formatter used the defaults.
- When a module includes `SemanticLogger::Loggable`, its instance methods can now call `logger` in a
  class that includes the module without including `SemanticLogger::Loggable` itself. Before, they
  raised `NoMethodError`. The logger is named after the class, and the class is otherwise unchanged.
  A class with a class level `logger` of its own keeps using it, as before. See
  [The Loggable mixin](https://logger.reidmorrison.com/api.html#the-loggable-mixin-recommended).
- The default, color, and syslog text formatters no longer write a blank line after an exception that
  has no backtrace, such as a Rails routing error or an exception that was never raised, or after a
  cause that has no backtrace. The line break after the exception is now written only when exception
  details, a backtrace, or a cause follow it. The `%{backtrace}` pattern directive and the
  `exception.stacktrace` attribute of the `:open_telemetry` appender no longer start or end with a
  line break in those cases either.
- Tags, named tags, and `logger.with_level` levels are no longer shared between threads that copy
  fiber-local variables, as Rails' `ActionController::Live` does for its streaming thread. Semantic
  Logger changed their lists in place, so when the request left its `tagged` block, the streaming
  thread lost the request's tags, and a tag pushed in either thread appeared in the other. Each
  change now stores a new frozen list, and a `tagged` block restores the previous one when it exits.
  As a result, tags pushed with `push_tags` or `push_named_tags` inside a `tagged` block, and not
  popped, are removed when the block exits. Before, the block popped them in place of its own tags,
  which then stayed on the thread. Likewise, tags pushed before a block and popped inside it come back
  when the block exits. See the [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- `logger.backtrace` on a child logger, one returned by `logger.tagged` without a block, logs the
  child logger's own tags, as its other entries do. They were left out.
- A thread dump (`logger.backtrace(thread:)`, and the `TTIN` signal handler) logs the named tags of
  another thread as a Hash. They were logged as the list of Hashes pushed by each `tagged` block,
  which the text formatters could not format, so the thread's entry was discarded.
- The `:open_telemetry` appender no longer sends a named tag whose value is a Symbol, Time, or other
  object that is not an OpenTelemetry attribute value as an empty value. It is sent as its `#to_s`,
  or as JSON for a structure, as payload values already were.
- The `:open_telemetry` appender sends every element of a payload or named tag Array that mixes
  types, such as `[1, "two"]`, as a String, and a subclass of String, such as
  `ActiveSupport::SafeBuffer`, as a String. The OpenTelemetry SDK reported either value as an error,
  for every log entry; with `OpenTelemetry.logger` set to a Semantic Logger logger in sync mode, that
  error was logged back to the appender with the same named tags until the stack overflowed.
- The `:loki` formatter writes the `stack_trace` of an exception one frame per line, followed by the
  backtrace of each exception that caused it, as the text formatters do. It wrote the backtrace as
  an inspected Ruby Array, such as `["app/a.rb:1:in 'A#a'", ...]`, and left out the causes.
- The `:syslog_cee` formatter accepts the options of the `:raw` formatter, such as `log_host` and
  `log_exception_details`, given to the formatter or with `formatter: {syslog_cee: {...}}`. It
  raised `ArgumentError` for them.
- The `:open_telemetry` and `:new_relic_logs` appenders keep the trace context they capture as an
  entry is logged with the new `Log#capture`, which formatters do not write, instead of in the log
  context. The `:loki` formatter, which writes each value of the context as a stream label, wrote
  the OpenTelemetry context as a label such as `#<OpenTelemetry::Context:0x...>`, and the New Relic
  linking metadata as one holding the trace and span ids, so Loki created a new stream for each span.
  A custom formatter that read `log.context[:open_telemetry]` or `log.context[:new_relic_metadata]`
  reads `log.captured(:open_telemetry)` or `log.captured(:new_relic_metadata)` instead, and an
  `on_log` subscriber that set either key with `log.set_context` sets it with `log.capture`.
- The `:sentry_ruby` appender sends each entry with the Sentry context of the thread that logged it:
  the user, tags, contexts, breadcrumbs, trace, and event processors that `sentry-ruby`,
  `sentry-rails`, or the application set for it, without the request's url, headers, and body. It
  sent the entry from the appender thread, with that thread's empty Sentry scope, so the event had
  no trace, and no user other than the one taken from the named tags. The user taken from the named
  tags is merged into the thread's Sentry user.
- The `:loki`, `:open_telemetry`, and `:new_relic_logs` appenders use their own formatter when given
  `formatter: nil`, or when their formatter is set back to `nil` with `formatter=`. They used the
  generic default instead: JSON for Loki, and plain text for the others, which made every log entry
  fail for OpenTelemetry.
- The `:sentry_ruby` appender no longer loses an event whose data holds a binary String that holds
  bytes outside ASCII, such as a response body in the payload, with json 3.1, and no longer prints
  the json gem's warning about it with json 2.8.0 through 3.0.x. Sentry serializes the event itself,
  so it raised as Sentry sent the event, which dropped it. Now the appender hands Sentry a copy of
  the data with its text converted to valid UTF-8, as the JSON formatters write it: binary text is
  read as the UTF-8 it usually holds, and invalid bytes are dropped. The `:bugsnag`, `:honeybadger`,
  and `:honeybadger_insights` appenders now hand over such a copy too, keeping the characters of
  binary text: Bugsnag replaced each of its bytes outside ASCII with U+FFFD, and Honeybadger with "?",
  so `"Café".b` arrived as `"Caf\uFFFD\uFFFD"` or `"Caf??"`. A Hash or Array nested more than 32 levels
  deep, or that holds itself, is cut off there, as the JSON formatters cut it off, so a payload that
  holds itself no longer makes Sentry drop the event either. Any other object in the data is handed
  over as it is, for the service to write as before, and the message of a logged exception is still
  the service's to convert.
- The `:mongodb` appender no longer discards an entry that holds text BSON cannot store: a binary
  String that holds bytes outside ASCII, such as a response body in the payload, a US-ASCII String
  that holds UTF-8, such as a file read where no locale is set, invalid UTF-8, such as an exception
  message that quotes invalid input, a key in another encoding, such as ISO-8859-1, or a key with a
  NUL byte. Before, BSON raised, and the appender reported the error to the internal logger instead of
  storing the entry. Now such an entry is stored as a copy with its text converted, as the JSON
  formatters write it: binary text is read as the UTF-8 it usually holds, invalid bytes are dropped,
  and NUL bytes are removed from keys. Only an entry that BSON refuses is copied, and such an entry
  nested more than 32 levels deep is cut off there, as the JSON formatters cut it off.
- The file appender's `reopen_size` counts the bytes written, as documented. It counted characters,
  so a log file of text in Chinese or Japanese, or with emoji, grew to up to four times the size
  before it was reopened. An entry whose text the file refuses even converted (see the next entry) no
  longer makes the appender close and reopen the log file before the entry is discarded, since
  reopening cannot fix the text.
- The file and IO appenders no longer discard an entry whose text the file or IO refuses in its
  encoding. A file opened with an `encoding:` such as `"UTF-16LE"` converts what it writes, and
  raised `EncodingError` for invalid UTF-8, for binary text that holds bytes outside ASCII, which a
  custom formatter can return, or for a character its encoding does not have. An IO that converts to
  UTF-8, such as one opened after Rails sets `Encoding.default_internal`, raised it for such binary
  text. Now such an entry is written converted, as the JSON formatters convert text: binary text is
  read as the UTF-8 it usually holds, invalid bytes are dropped, and a character that the encoding
  does not have is written as `?`. Only an entry that the file or IO refuses is converted, so an IO
  that converts to UTF-8 still writes text tagged UTF-8 that holds invalid bytes as it is. Text is
  converted only for an IO, a `Tempfile`, or a `StringIO`: an IO appender given another object that
  responds to `#write` still loses an entry that the object refuses.
- The file and IO appenders no longer change the String that their formatter returns. They added the
  line break to it in place, so a custom formatter that returns a String it does not own, such as
  `->(log, _) { log.message }`, appended a line break to the application's own message, and one that
  returns a frozen String, such as a message from a file with `# frozen_string_literal: true`, raised
  `FrozenError`, which the appender took for a failing destination: the entry was discarded, and an
  async appender waited before carrying on. A formatter that returns something that is not a String
  and does not convert to one (`#to_str`), such as nil, raised `NoMethodError`, taken the same way,
  and one that returns an Array had it written as an Array; either is now the entry's own error, so
  it is discarded without waiting.
- A logger or appender with a Regexp `filter:` no longer raises `ArgumentError` or
  `Encoding::CompatibilityError` into the application when the logger's name is not valid in its
  encoding, such as a name built from binary input, or not ASCII-compatible, such as UTF-16, or when
  the Regexp is fixed to another encoding, such as one from a source file in ISO-8859-1, and the
  name holds characters outside ASCII. The name is matched converted to valid UTF-8, or to the
  Regexp's encoding, and a name that it still cannot match does not match. The `:ecs` and
  `:new_relic_logs` formatters no longer lose an entry whose stack trace mixes lines in encodings
  that cannot be joined, such as a UTF-16 line, or a binary line next to a UTF-8 one, in a backtrace
  set by the application, and the SignalFx metrics formatter no longer loses one whose metric name
  is not valid UTF-8; such text is converted to valid UTF-8.
- `escape_control_chars: true` now also escapes the Unicode characters that control how text is
  shown, as `\uXXXX`: the C1 control characters (U+0080 to U+009F), which some terminals act on, the
  line and paragraph separators (U+2028, U+2029), at which editors, browsers, and some log viewers
  start a new line, and the bidirectional controls (U+202A to U+202E, U+2066 to U+2069), such as the
  right-to-left override, which can make logged text, such as a forged `user=admin`, read in another
  order than it was written. It escaped only the ASCII control characters. The `:syslog` formatter,
  and the syslog appender's own formatter, escape by default, so their output changes too. Text that
  is all ASCII is checked as quickly as before. See
  [Upgrading to v5.3](https://logger.reidmorrison.com/upgrading.html#upgrading-to-semantic-logger-v53).
- `:one_line` shortens the thread name to 30 characters before escaping it, as the other text
  formatters do. It shortened the escaped name, so with `escape_control_chars: true` an escape near
  the end, such as `\e` or `\u2028`, could be cut in two, leaving a lone backslash.
- The text formatters (`:default`, `:color`, `:one_line`, `:pattern`, `:syslog`) shorten a binary
  thread name that holds UTF-8 to 30 characters rather than 30 bytes. They split the character at
  the cut, and wrote fewer characters, such as 15 for a name of 40 `é`.
- Text tagged with Ruby's `Encoding::UTF_16` or `Encoding::UTF_32` that has no byte order mark is
  now written as the text it holds, read as big-endian as Unicode reads such text. Ruby's converter
  for those encodings needs the byte order mark, so every formatter that converts text to UTF-8
  wrote it as an empty String. Text tagged with an encoding that names its byte order, such as
  `Encoding::UTF_16LE`, is converted as before.
- The `:syslog` and `:syslog_cee` formatters, which build the records of the TCP and UDP syslog
  appenders, no longer lose every entry when the host or application name holds a character
  outside printable ASCII, such as `"Café"`, a tab, or a space in the host name, or when the
  application name is over 32 characters. The `syslog_protocol` gem raised for such a header, and
  the appender reported the error to the internal logger instead of sending the entry. Now those
  characters are left out of the header, as spaces always were from the application name, the
  application name is cut to 32 characters, and a name with no character left is written as
  `localhost` or `SemanticLogger`. Each name is worked out once, and again only when it changes.
- The `:new_relic_logs` formatter, and so the `:new_relic_logs` appender, no longer loses an entry
  whose exception has no backtrace, such as `logger.error("Failed", RuntimeError.new("never raised"))`.
  Formatting raised `NoMethodError`, and the appender reported the error instead of sending the
  entry. Its `error.stack` is now empty.
- When Elasticsearch or OpenSearch does not index some of the entries that the `:elasticsearch` or
  `:opensearch` appender sends, the error that the appender reports to the internal logger names only
  those entries. Before, it listed the server's response for every entry of the request, up to 300 in
  a batch by default, including the ones that were indexed, since it read each entry's status from
  the wrong place. Now it says how many of the entries were not indexed, and groups them by status,
  error type, index, and the innermost error that caused it, up to ten groups, each with its number
  of entries and the reason of its first, followed by each error that caused it. A reason is quoted,
  with its control characters escaped, without the lines after its first, where the server can add
  part of the document, and cut to 500 characters.
- The `:new_relic` metric subscriber adds its prefix, `Custom` by default, and a `/` to a metric name
  that starts with the prefix but not with the prefix and a `/`, such as `Customers/signup` or
  `CustomerSignup`. Before, it recorded such a name as it was, since it only checked that the name
  started with `Custom`, and New Relic charts custom metrics only under `Custom/`. A name that starts
  with `Custom/` is still recorded as it is, and an empty prefix still adds nothing. A prefix given
  with a trailing `/`, such as `Custom/`, is added with one `/`. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- The formatters that write the backtrace of each exception that caused the logged one (`:default`,
  `:color`, `:pattern`, `:syslog`, `:loki`, and `:open_telemetry`) no longer lose the entry when the
  `#message` of a cause raises, such as one that reads a record that is nil, or an abstract one that
  raises `NotImplementedError`; the error was reported to the internal logger instead. They now
  write the message the cause was raised with, as `log_exception: :partial` does. A cause of an
  anonymous class is named as Ruby writes the class, as in `Cause: #<Class:0x000...>: disk full`,
  rather than `Cause: : disk full`. For custom formatters, `Log#backtrace_to_s`, which these use,
  always passes its block a String, even for a cause whose `#message` returns nil, and no longer
  raises `Encoding::CompatibilityError` for lines it cannot join as they are, such as a UTF-8
  backtrace line and a cause's binary message, which it now joins as UTF-8. It also joins as UTF-8
  binary or US-ASCII backtrace lines that hold bytes outside ASCII, such as Ruby's own where no
  locale is set in a directory such as `café`, rather than returning the whole text as binary or
  as invalid US-ASCII. `Log#exception_details` returns nil, rather than raising, when the
  exception's `#message` raises `NotImplementedError`.
- The `:signalfx` metric subscriber sends a metric whose dimensions are all blank, such as
  `dimensions: {state: ""}` or `{supplier: nil}`, as it sends a metric without dimensions: a duration
  as `Application.average` and `Application.counter`, and a count as `Application.counter`, each with
  the `class` and `action` taken from the metric name and the named tags listed in its `dimensions:`
  option. Before, it sent such a metric under its own name, with only the `host`, `application`, and
  `environment` dimensions, since it left out the blank values, and a duration without a count. A
  blank value is `nil`, or text that is empty or only whitespace; a value of only whitespace, which it
  sent before, is now also left out of dimensions that have other values, and of the named tags it
  forwards. `Log#dimensions?`, which the formatters that write an entry's data ask, still counts such
  dimensions. Without a `dimensions:` option it no longer reads the named tags, so a named tag whose
  key cannot be turned into a Symbol, such as an Integer, no longer stops the metric being sent. See
  the [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- `SemanticLogger::Processor.logger=` accepts a Ruby or Rails Logger, such as `Logger.new($stderr)`,
  as its comment says, to receive Semantic Logger's reports of its own problems, such as an appender
  that fails. Before, adding the first appender, or logging the first entry, raised `NoMethodError`
  (undefined method 'name='), and such a logger could not take the reports, which log at `:trace` and
  pass the exception after the message. The logger is now wrapped in an appender, which
  `Processor.logger` returns, and which writes each report to it as text, with the exception. The
  logger's own level decides which reports it writes, apart from the `:trace` reports, which are
  below its lowest level, so are left out. A logger that logs at `:trace`, such as an appender, is
  kept as it is. A `SemanticLogger::Logger`, which the comment rules out, now raises `ArgumentError`:
  its reports of an appender that fails went back to that appender, failed again, and were reported
  again, without end. The same goes for `SemanticLogger::SyncProcessor.logger=`.
- `SemanticLogger.reopen` within the same process, such as `reopen(force: true)` after a log
  rotation, keeps the log entries that are still queued, and writes them in order, ahead
  of those logged after it. Before, it replaced the queue, so the entries on it were lost, and
  stopped the thread writing them, even in the middle of an entry, which was lost too; a log call
  waiting for room on a full queue raised `ClosedQueueError`. That thread now keeps running, and is
  only started again once it has stopped, such as after `async_max_retries`. After a fork, the child
  still starts with an empty queue, since the parent process writes the entries it had queued. The
  same goes for an appender added with `async: true` or in batches. See the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- A log call in a signal trap, such as the log level change (`USR2`) or thread dump (`TTIN`) of
  `SemanticLogger.add_signal_handler`, no longer raises `ThreadError` ("can't be called from trap
  context") when `SemanticLogger.non_blocking` is on and the queue is full, or the thread that writes
  the log entries has stopped. Counting the dropped message locked a Mutex, which Ruby does not
  allow in a trap. The message is now dropped and counted, as outside a trap, and reported just
  after the trap, at most once every `dropped_message_report_seconds` as before. On Ruby 4.0,
  `SemanticLogger.reopen` in a signal trap, such as after a log rotation, no longer raises
  `ThreadError` either: reopening the thread that receives the entries logged in other Ractors
  locked a Mutex, even when it had nothing to do.
- The `:http`, `:elasticsearch_http`, `:splunk_http`, and `:loki` appenders, and the `:signalfx`
  metric subscriber, no longer count an entry that the server did not accept as written. They
  reported a response other than 2xx to the internal logger and carried on, so with `async: true` or
  `batch: true` such entries were counted as `processed` in `SemanticLogger.stats`, a batch that the
  server rejected for one entry lost every other entry with it, and while the server was unavailable,
  such as Loki restarting, the worker thread kept sending, and losing, each entry or batch at once.
  Now a 4xx other than 408 and 429 discards the entries straight away. A batch the server rejects for
  the entries it holds, with a 400, 413, or 422, is first split up and sent again in parts, so that the
  entries in the parts the server accepts are written; one it rejects whatever it holds, such as with
  a 401, 403, or 404 for a wrong password or url, is discarded at once, with one report. Any other
  status is a problem with the destination, so the worker thread backs off before sending again, and
  the entries logged meanwhile wait on the queue: a 408, 429, or 503 sends the same entry or batch
  again (see the entry on sending again after an outage), and any other, such as a 500, 502, 504, or
  redirect, discards it. The entries discarded are counted as `failed`, and reported with the status
  code, the url without its credentials, and the start of the response body. See
  [When the server does not accept a request](https://logger.reidmorrison.com/appenders.html#when-the-server-does-not-accept-a-request)
  and the [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- An appender added with `async: true` or in batches keeps logging in the child process after a fork
  when it cannot be reopened, such as `:udp` once its server's name no longer resolves, or `:http`
  while its server cannot be reached. Before, the error from the appender's own `#reopen` also kept
  the thread that writes its entries from starting in the child, so they waited on its queue for
  ever, and once that queue was full every log call blocked. The thread is now started, and the error
  is still reported to the internal logger, as `Failed to re-open appender`. The same goes for
  `SemanticLogger.reopen(force: true)` within the same process, once that thread has stopped.
- A log call waiting for room on the full queue of an appender added with `async: true` or in
  batches no longer waits for ever once the thread that writes its entries gives up after
  `async_max_retries`: within a second it drops its entry, counted as `dropped`, and carries on. That
  log call is normally made by the thread that writes to every appender, so before, all logging
  stopped, and the flush at exit never finished. A flush of that appender waiting for room on its
  queue stops waiting the same way. The entries already on the queue are kept, for
  `SemanticLogger.reopen(force: true)` to write. The report of dropped entries then says that thread
  has stopped, rather than advise a larger `max_queue_size`. With `max_queue_size: -1`, a log call
  once that thread has given up now queues its entry, rather than raising `ArgumentError`. After a
  fork, that thread in the child process now starts its count of failures afresh, where v5.2.0
  carried on with the parent's count.
- `SemanticLogger.reopen`, often called from a signal trap after a log rotation, no longer reopens an
  appender while it is writing. It reopened each appender on the calling thread, while the thread
  that writes the entries could be writing to it: the file appender could close its file under an
  entry being written, which it then wrote again, to the new file, and the HTTP appenders could end a
  connection under a request, and, with some versions of the timeout gem, fail in a signal trap with
  `ThreadError` when the timeout of the new connection locked a Mutex. Now each appender is reopened
  by the thread that writes its entries, before it writes the next one, so `reopen` returns before
  the appenders have reopened, and can be called from a signal trap. An appender that cannot be
  reopened is reported by that thread, and carries on with what it had. `SemanticLogger.sync!` still
  reopens on the calling thread each appender without a thread of its own (added without `async:`
  or batching). See
  [Process forking](https://logger.reidmorrison.com/operations.html#process-forking) and the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- The formatters no longer lose an entry when the `#message` of its exception raises, such as one
  that reads a record that is nil, or an abstract one that raises `NotImplementedError`: `:raw`, and
  so `Log#to_h` and the formatters built on it (`:json`, `:logfmt`, `:fluentd`, `:ecs`,
  `:syslog_cee`, and `:new_relic_logs`), which also read each cause's message, and `:default`,
  `:color`, `:one_line`, `:pattern`, `:syslog`, `:open_telemetry`, and the `:graylog` appender. The
  error was reported to the internal logger instead, and the error service appenders that use
  `:raw`, such as `:bugsnag`, `:honeybadger`, and `:sentry_ruby`, did not send the exception at all.
  They now write the message the exception, or the cause, was raised with, and `:raw` writes a
  `#message` that returns something other than a String, such as nil or a Symbol, as a String.
  Every formatter, `log_exception: :partial`, and the internal reports now name an exception's class
  as Ruby does in `Exception#inspect`, without calling the class's own `self.name`, `self.to_s`, or
  `self.inspect`. So a `self.name` that raises no longer loses the entry in `:raw` and the formatters
  built on it, `:loki`, and `:open_telemetry`, nor, for an exception that caused the logged one, in
  the text formatters, and a `self.to_s` that raises no longer loses the entry in the text
  formatters, nor raises from `log_exception: :partial`. An exception of an anonymous class is named
  as Ruby writes the class, such as `#<Class:0x000...>`, where `:raw` wrote no name. A class that
  overrides `self.name` or `self.to_s` is named by the constant it was assigned to, rather than by
  what `self.name` returns in `:raw`, `:loki`, and each `Cause:` line, or what `self.to_s` returns in
  the text formatters and `log_exception: :partial` (see the
  [v5.3 upgrade notes](https://logger.reidmorrison.com/upgrading.html)). A class named in another
  encoding, such as one from a source file in ISO-8859-1, is named in UTF-8, so that the text
  formatters no longer lose an entry whose exception's message holds UTF-8 text outside ASCII.
  `:graylog` also no longer loses an entry logged with only an exception whose message holds bytes
  that are not valid UTF-8. A formatter that raises a `ScriptError`, such as `NotImplementedError`,
  now loses only that entry, as for any other error. Before, it stopped an appender added with
  `async: true` or `batch: true`, which then dropped every entry after it.
- The `:tcp` appender, and the `:syslog` appender over TCP, keep the `handshake_timeout:` of their
  `ssl:` option when they connect again after a reopen, such as the one that runs in the child
  process after a fork, and no longer change the Hashes they are given. Net::TCPClient takes
  `handshake_timeout:` out of the `ssl:` Hash it is given, which was the application's own Hash, so
  after a reopen the TLS handshake timed out after `connect_timeout:` instead, and a frozen `ssl:`
  Hash made `add_appender` raise `FrozenError`, with or without that key. The `:syslog` appender also
  wrote the server from its `url:` into its `tcp_client:` Hash, which raised `FrozenError` for a
  frozen one. Each connection now gets a copy of these options.

## [5.2.0] 2026-10-30

### Security

- The HTTP appender, and the appenders built on it (`:elasticsearch_http`, `:splunk_http`,
  `:loki`, and the `:signalfx` metrics appender), no longer write credentials to the internal
  logger when the server rejects a request. The logged url keeps only the scheme, host, and
  port, omitting the user, password, path, and query string (any of which can carry a token or
  api key), and the response body is truncated to 512 bytes. The error raised for an invalid
  url no longer includes the url, nor does the one for an invalid `proxy_url:`, or an invalid url
  given to the `:loki`, `:elasticsearch`, `:opensearch`, `:syslog`, or `:graylog` appenders or the
  `:statsd` metrics appender, or an invalid seed broker given to the `:kafka` appender, whose client
  gems put it in their errors.
- `#inspect` on every appender shows only the class, the object address, and what that appender
  says is safe to show, such as its url without credentials, its log group, or its queue name,
  instead of every instance variable. The `:elasticsearch` and `:opensearch` appenders showed the
  password in their url, `:rabbitmq` its password, `:kafka` its TLS private key and SASL
  passwords, `:cloudwatch_logs` its AWS credentials, and `:tcp` and `:syslog` their TLS options,
  for example whenever `SemanticLogger.appenders` was printed in a console or an error report. The
  proxy that `async: true` or `batch: true` wraps an appender in does the same: it shows whether it
  batches and the appender's own `#inspect`, instead of every instance variable of the proxy and of
  its queue processor.
- The `:sentry_ruby` appender no longer deletes the keys it reads from the log entry's payload and
  named tags, which it shares with every other appender and which can be the application's own
  Hash: the user fields and `fingerprint` it took for Sentry were missing from every appender
  after it, and from the application's Hash. A `fingerprint` that is not an Array of Strings,
  Symbols, or numbers, or a payload that is not a Hash, is sent to Sentry as data instead of
  raising, which lost the error report. Taking the user and fingerprint from the payload, which can
  hold untrusted data, is deprecated; set them with named tags instead. Until then the named tags
  win: a user field or `user` Hash in the payload no longer replaces one they set, and only a String,
  Symbol, or Integer is taken from the payload for a user field, so other values are sent as data.
- The `:cloudwatch_logs` appender splits the buffered log messages into batches that PutLogEvents
  accepts (at most 1 MB and 10,000 events, in chronological order), cuts short a message too large
  for a batch of its own, and reports a request that fails to the internal logger. It sent up to
  4,000 messages in one request, which AWS rejects once over 1 MB, for example when one logged
  value is large, and the error was swallowed by the flush timer, so every message in the batch was
  lost without a trace. Each message is now formatted when it is logged, so that one that AWS would
  reject along with the rest of its request (the formatter fails, or returns something other than a
  String with content) is discarded on its own, and invalid UTF-8 is repaired. A failure to create a
  missing log group or stream is reported too, instead of stopping the remaining batches, as are the
  messages that AWS rejects from a request it accepts, for being too new, too old, or past the log
  group's retention period.
- The `:statsd` metrics appender sends a counter as a single packet (`metric:amount|c`),
  instead of one increment packet per unit of `metric_amount`. A large amount, for example
  one derived from user input, could otherwise flood the network and stall the logging
  thread. Amounts that are not finite (`Infinity`, `NaN`) are ignored.
- `escape_control_chars` now also escapes the message of each exception that caused the
  logged exception (`Cause: ...` in the backtrace), and each backtrace line, in the
  `:default`, `:color`, `:pattern` (`%{backtrace}`), and `:syslog` formatters. Previously a
  newline in a cause, which often quotes untrusted input, could forge a log entry even with
  escaping enabled. It also escapes the logger name, the thread name, the payload, whose
  `#inspect` output can carry control characters from untrusted data, and the file name taken from
  the first line of the backtrace, which a log call can supply (`backtrace:`) from untrusted data;
  the `:color` formatter then renders the payload without Amazing Print colors, on one line.
  Escaping also drops invalid UTF-8 bytes instead of raising, which lost the log entry.
- The `:syslog` formatter, which escapes control characters by default, now keeps an entry
  with an exception on a single line, escaping the newlines between the exception and its
  backtrace, so that a receiver framing records by newline does not split it.
- The `:one_line` formatter honours `escape_control_chars` for the message and the exception
  message, which it previously ignored, letting carriage returns and ANSI escape sequences
  through. It also strips carriage returns, not only newlines, by default, and does so in the
  name, thread name, file name, tags, named tags and payload as well, so an entry stays on one
  line.
- The `:logfmt` formatter replaces spaces, control characters, invisible format characters (such
  as a zero width space or a right-to-left override, which could make a key pass for `level`),
  `=`, and `"` in keys with `_`. Keys come from tags, named tags, and the payload, and were
  written verbatim, so a tag such as a User-Agent could inject fields (for example
  `level="fatal"`) or a whole new line. A key named like one of the entry's own fields, which are
  the time key (`timestamp` by default), `level`, `name`, `message`, `duration`, `duration_ms`,
  `tag`, and the exception fields, is emitted with its source as a prefix, such as
  `payload.level`: a payload with Symbol keys, including the explicit `payload:` recommended for
  untrusted hashes, replaced those fields outright, so that `{"level": "fatal", "message": ...}`
  in a webhook body forged the whole entry. A key that starts with `tags.`, `named_tags.`, or
  `payload.` is prefixed too, as in `payload.named_tags.level`, so that it cannot pass for another
  source's field. A logged exception's class and message are emitted as `exception_name` and
  `exception_message`, which previously replaced the entry's own `name` and `message`, and the
  detail that `log_exception_details: true` adds as `exception_details`. Other keys that are the
  same once encoded, such as `:user` and `"user"`, are now emitted once, with the value from the
  later source: the payload over named tags, and named tags over tags. Nested values (a Hash, an
  Array, or any other value whose JSON is an object or an array, such as a `Set` or the exception
  backtrace) are emitted as quoted JSON instead of their `#inspect` text, which could print an
  object's instance variables.
- The JSON based formatters no longer drop a log event whose payload JSON cannot represent.
  `Infinity` and `NaN` (for example `params[:amount].to_f` with `"1e400"`) are serialized as
  strings, and a structure nested too deeply, such as a request body as deep as `JSON.parse`
  accepts logged inside the request params, is replaced below 32 levels with a placeholder
  such as `"#<Hash nested too deeply>"`. Previously the whole event failed to serialize, so an
  attacker could keep their own request out of JSON logs. A `Struct` or `Data` in the payload
  is now serialized as an object of its members, as ActiveSupport does, instead of as its
  `#inspect` string, which listed the instance variables of any object held in a member (such
  as a client's password) and had no depth limit, so a deep enough structure failed with
  `SystemStackError`. The same now applies to a `Set` (written as an array) and an `OpenStruct`
  (an object), a structure used as a Hash key is written as its JSON, and an exception, or any
  other object whose JSON fails because of invalid UTF-8, is written as its `#to_s` with the invalid
  bytes dropped, instead of the entry being dropped. The `:elasticsearch` and `:opensearch`
  appenders serialize each bulk line this way instead of with their client gem, which wrote
  `Infinity` as a bare word and dropped an entry holding a binary String such as a User-Agent, and
  discard an entry that still cannot be serialized rather than stalling; the `:graylog` appender
  hands GELF a repaired copy when it needs one. The `:loki` and `:open_telemetry` formatters write a Struct,
  Set, or other structure in the payload as JSON instead of its `#inspect`.
- A log message tagged UTF-8 that holds invalid bytes, such as a request parameter that Rack
  decodes from `?q=%1B%FF`, or in another encoding, such as a binary request body, no longer makes the structured formatters (`:json`, `:raw`, `:fluentd`,
  `:ecs`, `:logfmt`, `:loki`, `:open_telemetry`, `:syslog_cee`) or `:one_line` raise; the invalid
  bytes are dropped, as they already were in the payload. Previously the entry was lost, and on an
  async or batching appender (`:elasticsearch` and `:opensearch` batch by default) the whole batch
  was lost and the worker backed off, so one such request every few seconds kept the appender from
  writing anything until it stopped for good.
- The `:loki` formatter writes a nested value in the payload once, as JSON. It encoded each level
  into a String that the next level encoded again, doubling the escaping at every level, so a
  request parameter nested 30 levels deep, as Rack accepts and rails_semantic_logger logs with
  every request, made a single log entry of gigabytes and could exhaust the process's memory. A
  payload that is not a Hash is written as a single `payload` field instead of raising, as it is by
  the `:open_telemetry` formatter, which submits it as a single attribute.
- An async or batching appender no longer lets one log message that cannot be written stall
  the others. A message that fails because of its content, as decided by the appender's
  `#message_error?`, is discarded, reported, and counted as `failed` in
  `SemanticLogger.stats[:appenders]`, without the worker thread backing off. That is any error
  raised by the appender's formatter (the built-in appenders format through the new
  `Subscriber#format_log`, which raises it as a `Subscriber::FormatError`), a JSON generator,
  encoding, or `FloatDomainError`, a log message too large for a UDP datagram (by the `:udp`
  appender, or `:syslog` over UDP), a MongoDB document that BSON cannot serialize, and a message
  GELF cannot send. In a batch sent as a single request (the HTTP, Loki, Splunk HTTP, SignalFx,
  Elasticsearch, and OpenSearch appenders, or any whose `#batch_all_or_nothing?` is true), only
  that message is discarded instead of the whole batch; in any other batch the whole batch is
  discarded, as before, so no message is written twice. Previously a few such requests per second
  could keep the worker asleep until its queue filled and every `logger.*` call in the application
  blocked.
- A log message that overflows the stack while it is written (`SystemStackError`, for example a
  value nested too deeply for a custom formatter) is discarded and reported, and the worker thread
  of the async appender, or of the logging pipeline, carries on in a new thread. Previously it
  stopped the worker for good, and on macOS a second overflow on the same thread crashed Ruby: the
  pipeline thread logged it and carried on, so two such messages through a plain file appender
  crashed the process. A batch that overflows is discarded rather than split up to find the
  message at fault, since that would overflow again on the same thread. With `SemanticLogger.sync!`
  the overflow is reported instead of being raised from the log call.
- A payload nested too deeply for `#inspect` (a few hundred levels, for example a body parsed with
  `JSON.parse(body, max_nesting: false)`) no longer fails to format in the text formatters, or makes
  a log call raise when given as its `exception`. It is written as the JSON formatters write it,
  cut off below 32 levels with their placeholder (so a Struct is written as a Hash of its members,
  and `NaN` as a String). Previously the entry was lost.
- The `:new_relic_logs` appender reports a failure to the internal logger. It logged the failure
  through itself, which recursed until `SystemStackError`.
- The `:graylog` appender sends a placeholder `short_message` for a message that is empty once
  escape codes and surrounding whitespace are removed, and has no exception message to use instead,
  which Graylog rejected.
- Once an async appender's worker thread gives up after `async_max_retries`, new log messages
  are dropped when its queue is full, instead of blocking the calling thread forever, and a
  flush (including the one at exit) waiting on it returns instead of waiting forever. A flush
  or close taken off the queue with a batch that could not be written is now still run,
  instead of being lost and leaving its caller waiting forever.
- A hash passed as the payload of a log call can no longer make the call raise. Previously,
  logging `params.to_unsafe_h` raised `ArgumentError` whenever the request carried a `payload`
  parameter (since `HashWithIndifferentAccess#key?(:payload)` matched it), and a hash with an
  invalid `log_exception`, `on_exception_level`, `min_duration`, or `backtrace` raised too. A key
  is now only used as a log argument when its value is valid for it (for example a finite, real
  `duration`); otherwise it stays in the payload, and a `nil` value is ignored. Unknown keys
  alongside an explicit `payload:` are merged into it instead of raising, and win over its values
  of the same name (a String key such as `"account_id"` has the same name as `:account_id`), so
  that untrusted data passed as the payload cannot replace a value such as an `account_id` that
  the application supplied beside it. The options of `measure_*` calls are
  checked the same way, an invalid value being ignored, and so is a Hash returned from a logging
  block, as in `logger.info("Webhook") { JSON.parse(body, symbolize_names: true) }`: it assigned
  every key unchecked, so `{"payload": null}` made the call raise, a `duration` or `exception` of
  the wrong type made every formatter drop the entry, its `message` replaced the application's own,
  and its other keys were written into the caller's payload Hash. A block's log arguments, such as
  its `message`, `duration`, or `backtrace`, are now only used when the log entry does not have them
  yet (a backtrace captured at the `backtrace_level` counts), and are otherwise kept in the payload,
  so the block never replaces a value the log call supplied. An
  `on_exception_level` given as a String or Integer is now stored as its Symbol, and a supplied
  `backtrace` Array is no longer modified. See [Logging untrusted hashes](https://logger.reidmorrison.com/security.html#logging-untrusted-hashes).
- The file appender's `permissions:` option is only applied to a regular file owned by the
  process with a single hard link, and not through a symbolic link or to a file swapped in after
  opening. Previously a link planted in a writable log directory made the appender change the
  permissions of the file it pointed at, for example loosening a `0600` private key to `0644`.
  Nothing is written to any other file either, since its owner, or whoever planted the link,
  could read the log messages despite the permissions asked for. With `permissions:`, the log file
  is opened without following a symbolic link, so a dangling link can no longer create the file it
  points at, and without blocking, so a FIFO fails to open instead of blocking the process.
  `add_appender` raises `IOError` giving the reason, also when the file cannot be opened, with the
  original error as its `cause`. When a later rotation or reopen finds such a file, for example one
  planted under the name of tomorrow's log file, the appender reports the reason once for each
  file, drops the log messages instead of raising, and tries the file again every few seconds.
  Without `permissions:`, writing through a symbolic link still works.
- `logger_measure_method` validates its arguments before writing them into the source of the
  method it generates. `min_duration` and the method name were written verbatim, so a value
  read from configuration, such as `min_duration: "(system('...'); 0)"`, would run as code on
  every call. A method name that is not a valid Ruby method name, a `min_duration` that is not a
  finite number, and an invalid `log_exception` or level now raise `ArgumentError`.
- The example of redacting sensitive data in [Security](https://logger.reidmorrison.com/security.html#redacting-sensitive-data)
  only matched top-level Symbol keys, so it missed the String keys of parsed JSON and Rails params
  and every nested Hash, and it wrote `"[REDACTED]"` into the application's own Hash when that was
  the logged `payload:`, changing data the application went on to use. It now redacts into a new
  payload, at any depth, whatever the type, case, and style of the key (`api_key`, `apiKey`, or
  `X-Api-Key`), including inside a Struct, Data, Set, OpenStruct, or
  `ActionController::Parameters`. It walks a structure held more than once only once, cuts off one
  that holds itself, and fails closed: a payload it cannot redact, for example one with a key that
  is not valid UTF-8, is replaced rather than written as it is. Replace any copy of the earlier
  example. The docs also no longer suggest redacting in an appender's `filter` or in a formatter,
  which only protects the appenders that run after it. To report a vulnerability, see the new
  `SECURITY.md`.

### Deprecated

- The `:splunk` appender is deprecated and will be removed in v6; use `:splunk_http` instead. Its
  `splunk-sdk-ruby` gem, last released in 2015, does not verify the server's TLS certificate.
  The appender has also not accepted connection settings since v4.1, so it could not be used.
  See the [v5.2 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
- The `:sentry_ruby` appender taking the Sentry user (`user_id`, `username`, `user_email`,
  `ip_address`, `user`) and `fingerprint` from the log payload is deprecated and will be removed in
  v6, since the payload can hold untrusted data. Set them with named tags instead, which can now
  also hold the `fingerprint`, for example `SemanticLogger.tagged(user_id: user.id)`. A deprecation
  warning is emitted the first time it happens.

### Added

- Exceptions are logged with the detail that Ruby's `Exception#detailed_message` adds to the
  message, such as did_you_mean suggestions (`Did you mean?  upcase`) or the detail an exception
  class supplies by overriding `#detailed_message`. Since Ruby 3.2 that detail is no longer part of
  `Exception#message`, which is all Semantic Logger logged. The `log_exception_details` formatter
  option controls it: `true` (the default for the `:default`, `:color`, and `:pattern` text
  formatters, so their output gains a line after the exception message when there is detail),
  `:with_source` to also log error_highlight's source snippet (much slower, since it re-parses the
  source file), or `false` (the default for every other formatter, so JSON and other structured
  output does not change unless enabled). Local syslog records do not change either. The `:json`
  formatter, and the others built on `:raw`, log it as `exception.details` (`:logfmt` as
  `exception_details`), and `:one_line` joins it onto the same line. The pattern formatter adds an
  `%{exception_details}` directive.
- `SemanticLogger.non_blocking = true` drops log messages instead of blocking the calling thread
  when the main pipeline queue is full. Previously `non_blocking:` could only be set on an
  individual async appender's own queue, so `logger.info` could still block on the main queue
  that every logger shares, for example when an appender that is not async slowed down. It can be
  set at any time, including after appenders are added.

### Changed

- Semantic Logger no longer replaces Ruby's `Thread#name` and `Thread#name=` with its own versions,
  which it added in 2013, before Ruby had them. Ruby's own versions give the name to the operating
  system, to profilers, and to `Thread#inspect`; Datadog's profiler, for example, turned itself off
  when it found the replacement. A thread that has no name is still logged with its object id (on
  JRuby, instead of its JVM thread name). Code that calls `Thread#name` now gets Ruby's behaviour:
  `nil` for a thread that has no name, a `TypeError` from `Thread#name=` for a value that is not a
  String or `nil`, and an `ArgumentError` for a String that contains a NUL byte or is not in an
  ASCII-compatible encoding. Semantic Logger's own threads are now named after their appender,
  such as `SL File`, so that they can be told apart on Linux, which keeps only the first 15 bytes
  of a thread name. See the [v5.2 upgrade notes](https://logger.reidmorrison.com/upgrading.html).
  Resolves #424.

### Fixed

- `flush` on the `:cloudwatch_logs` appender sends the buffered log messages itself. It waited, at
  full CPU, for the flush timer (every 5 seconds by default) to take them off the buffer, then
  returned before they were sent, so the messages logged just before the process exited could be
  lost.
- The `:syslog` and `:syslog_cee` formatters default `max_size:` to 1024 bytes. The default was
  the `Integer` class rather than a size, so a syslog formatter chosen explicitly without a
  `max_size:`, for example `appender: :syslog, formatter: :syslog_cee, url: "udp://..."`, failed
  on every log entry with `comparison of Integer with Class failed`. The syslog appender's
  `max_size:` now also reaches a `:syslog` or `:syslog_cee` formatter named by `formatter:`.
- Remote syslog over TCP or UDP sends the configured facility. The `facility:` option takes a
  `::Syslog::LOG_*` constant, which is the facility number shifted left by 3 bits, but it was sent
  unconverted, so the default `::Syslog::LOG_USER` went out as facility `uucp` (`<69>` for an
  `:info` message instead of `<13>`), and most other constants, such as `::Syslog::LOG_LOCAL0`,
  raised `ArgumentError` while logging. `facility:` now only accepts the `::Syslog::LOG_*`
  facility constants, and other values raise `ArgumentError` when the appender is created, except
  a bare 0, 8, or 16, which are read as `LOG_KERN`, `LOG_USER`, or `LOG_MAIL`. Syslog servers that
  route on facility, and configurations that passed a bare facility number, may need updating; see the
  [v5.2 upgrade notes](docs/upgrading.md). The syslog appender's `facility:` and `level_map:` now
  also reach a `:syslog` or `:syslog_cee` formatter named by `formatter:`, instead of being silently
  ignored, and setting `facility=` on a syslog formatter is validated the same way.
- The syslog appender and the `:syslog_cee` formatter accept `level_map:` as a Hash of overrides, as
  documented. With local syslog, a Hash sent a `nil` severity for every level it did not name, and
  `:syslog_cee` raised `ArgumentError`.
- `#inspect` on the HTTP appender and the appenders built on it (`:elasticsearch_http`,
  `:splunk_http`, `:loki`, and the `:signalfx` metrics appender) no longer shows credentials, for
  example when `SemanticLogger.appenders` is printed in a console. Only the object address and
  the scheme, host, and port of the url are shown, so the password, request headers (such as
  `Authorization` or a token header), the user, password, path, and query string of the url, the
  proxy url, and SSL options are omitted, as is anything a subclass adds. Every other appender
  now does the same, see Security above.
- The Syslog appender works on Ruby 3.4 and later. Ruby 3.4 moved `syslog` from the default
  gems to the bundled gems, and the appender required it even when logging to a remote syslogd,
  which does not use it. Now only a local syslog daemon needs `gem "syslog"`, and a clear error
  says so when it is missing. Logging to a local syslog daemon also no longer requires the
  `syslog_protocol` gem, which only the remote syslog formatters use; they load it when they are
  created rather than when their file loads. The syslog formatters define the
  severity and facility values they need as `SemanticLogger::Formatters::Syslog::LOG_*`.
- Semantic Logger loads on Ruby 4.0 without `logger` in the application's Gemfile. Ruby 4.0
  moved `logger` from the default gems to the bundled gems, so `require "semantic_logger"`
  raised `LoadError: cannot load such file -- logger` unless another gem happened to depend on
  it, and Ruby 3.4 warned about it. `logger` is now a declared runtime dependency.
- The HTTP appender keeps the query string of the url it is configured with, instead of
  silently dropping it, so log servers that take their settings as query parameters can be
  used. For example VictoriaLogs:
  `url: "http://localhost:9428/insert/jsonline?_msg_field=message&_time_field=timestamp"`.
  The query is applied after the request path, so it also works for the appenders that
  append their own path to the url: `:elasticsearch_http`, `:splunk_http`, `:loki`, and the
  `:signalfx` metrics appender.
- The Grafana Loki appender no longer loses the ingestion path when the url carries a query
  string. `url: "https://logs-prod-001.grafana.net?orgid=my_org"` now pushes to
  `/loki/api/v1/push?orgid=my_org`, instead of to `/?orgid=my_org/loki/api/v1/push`.
- The SignalFx metrics appender no longer sends the query string of its url twice, and in
  the wrong place. `url: "https://ingest.signalfx.com?orgid=my_org"` now posts to
  `/v2/datapoint?orgid=my_org`. Its internal `#full_url` reader is now `#full_path`, since
  it holds the request path rather than an absolute url.
- `SemanticLogger::Appender::ElasticsearchHttp#delete_all` no longer sends the query string
  of the url. The query configures how the server ingests log data, and Elasticsearch fails
  an index delete with a 400 when it carries unrecognized parameters.
- `logger.with_level` changes the level for the current fiber only, matching Ruby's
  `Logger#with_level`. It used to change the logger's level for every thread while the block
  ran, so with Sidekiq's per-job `log_level` the level leaked into other jobs running at the
  same time, and jobs that overlapped could leave the logger stuck at the wrong level. It also
  no longer pins a logger that follows the global default level to a fixed level, which had
  stopped later `SemanticLogger.default_level=` changes and `SemanticLogger.silence` from
  applying to that logger.
- In synchronous mode, an exception raised by an `on_log` subscriber is reported to the internal
  logger and the entry is still logged, as in asynchronous mode. It raised `NoMethodError` from the
  application's logging call instead, and the entry was lost.

## [5.1.0] 2026-07-20

### Deprecated

These are deprecated now and will be removed in v6. Each emits a Ruby deprecation warning
(`category: :deprecated`), so it is silent by default and shown when deprecation warnings are
enabled (for example `ruby -W:deprecated`, or Rails development mode).

- The `:sentry` appender (`SemanticLogger::Appender::Sentry`), which depends on the
  end-of-life `sentry-raven` gem. Use the `:sentry_ruby` appender instead.
- The `:new_relic` appender (`SemanticLogger::Appender::NewRelic`), which reports errors via
  `newrelic_rpm`. Use the log-forwarding `:new_relic_logs` appender instead.
- The `type:` parameter on the Elasticsearch and OpenSearch appenders (`:elasticsearch`,
  `:elasticsearch_http`, and `:opensearch`). Document `_type` has been unused since
  Elasticsearch 7, so the parameter is now ignored on all server versions: the bulk
  appenders no longer send a `_type`, and the HTTP appender now posts to `_doc`.

### Fixed

- The file appender opens its log file when it is created, so a misconfigured path or
  insufficient permissions now raise immediately from `SemanticLogger.add_appender`,
  instead of surfacing later on the appender thread via the internal logger while log
  messages are lost. This restores the pre-4.9 behavior and matches the other appenders,
  which already open their resources eagerly. As a result the log file is created as soon
  as the appender is added, even if nothing is logged (the same as the standard Ruby and
  Rails loggers).

## [5.0.0] 2026-06-29

### Breaking changes

See the [v5.0 upgrading guide](https://logger.reidmorrison.com/upgrading.html) for migration details.

- Ruby 3.2 is now the minimum supported runtime. Earlier versions are end-of-life and are no
  longer tested.
- Consolidate the asynchronous appender proxies: the worker thread and queue now live in an
  internal `SemanticLogger::QueueProcessor`, and `SemanticLogger::Appender::AsyncBatch` has been
  removed. `batch: true` now returns a `SemanticLogger::Appender::Async` (with `#batch?` true).
- Appenders are now reopened automatically in the child process after `fork` (and `Process.daemon`).
  A `Process._fork` hook calls `SemanticLogger.reopen` for you, so most applications no longer need
  an `after_fork`/`after_worker_boot` hook. Disable with `SemanticLogger.reopen_on_fork = false`.
  Resolves #338.
- Rename `SemanticLogger::Formatters::Base#cleanse` to `#escape_control_characters`. Custom
  formatters or subclasses that called the old method name must be updated.
- Syslog records now escape control characters by default to prevent log injection. Resolves #190.

### New features

- Add opt-in logger caching: `SemanticLogger.cache_loggers = true` makes `SemanticLogger[Class]`
  (and the `Loggable` mixin) return a single shared `Logger` instance per class, so a later
  `level=`/filter change is visible to every holder of that logger. Disabled by default; strings
  and anonymous classes are never cached. Use `SemanticLogger.clear_logger_cache` to discard the
  cache.
- Add per-logger (child logger) tags: calling `logger.tagged(...)` (or `with_tags`) without a
  block now returns a new logger instance that permanently carries the supplied positional and/or
  named tags, scoped to that logger only. Resolves #165. Combines the approaches from #301 (theocodes)
  and #321 (Fire-Dragon-DoL).
- Add a configuration-driven Pattern formatter (`:pattern`) that renders log layouts from a
  format string of directives. Resolves #78.
- Add an ECS (Elastic Common Schema) formatter (`:ecs`). Resolves #295.
- Add an OpenSearch appender (`appender: :opensearch`), sharing an Elasticsearch base. Resolves #189.
- Add batch support to the HTTP appender (`batch: true`), posting an array of log events per
  request. Resolves #278.
- Allow separate stdout and stderr console appenders so warnings and errors can be routed to
  stderr independently. Resolves #203.
- Add non-blocking (drop) mode for async appenders: `non_blocking: true` drops messages instead of
  blocking the calling thread once a capped queue is full, reporting dropped counts at most once
  every `dropped_message_report_seconds` (default `30`).
- Add retry-with-backoff for the asynchronous worker thread. When an appender raises while
  processing messages, the thread restarts with an increasing back-off and stops after
  `async_max_retries` (default `100`) consecutive failures instead of retrying forever. The
  counter resets after any message is processed successfully. Set `async_max_retries: -1` to
  restore the previous behaviour of retrying indefinitely.
- Add `SemanticLogger.stats` for operational metrics about the async queues (processed/dropped
  counts, queue depth). Distinct from application metrics. Resolves #164.
- Add an opt-in `escape_control_characters` option to the text formatters (default, color) to
  escape control characters in formatted output.
- Add a `permissions:` option to the file appender to restrict log file permissions on creation
  and on existing files.
- Add first-class RSpec test support (`SemanticLogger::Test::RSpec`), mirroring the existing
  Minitest helpers: `capture_semantic_logger_events`, the `be_a_semantic_logger_event` and
  `a_semantic_logger_event` matchers (with `message_includes` / `payload_includes` /
  `exception_includes` partial matches), and the `log_semantic_logger_event` block matcher.
  Resolves #371.

### Fixes

- Enforce UTF-8 encoding on JSON (and JSON-based) output to avoid `Encoding::UndefinedConversionError`
  on invalid byte sequences. Resolves #180.
- Fix the Fluentd formatter so `process_info` (pid, thread name) is excluded correctly. Resolves #190.
- Fix `ArgumentError` in `CaptureLogEvents#batch`. Resolves #327.
- Support zero-arity blocks and lambdas in the log methods, so `logger.info(&-> { "msg" })` no
  longer raises `ArgumentError`. Blocks that accept an argument still receive the `Log`. Resolves #361.
- Harden constant resolution and payload assignment against untrusted input.
- Fix the Minitest `assert_semantic_logger_event` helper so `exception_includes` no longer
  iterates `payload_includes`, which raised when `exception_includes` was given without
  `payload_includes`.

### Documentation

- Add a Security documentation page.
- Add upgrading guide to docs site covering v4.0 through v5.0, replace README upgrade sections with
  a link to the new page.

## [4.18.0]

- Fix the experimental OpenTelemetry formatter so its payload method coerces values.
  Ensures every attribute value is OTLP‑compatible.
- Fix missing trace.id/span.id in NewRelic logs
- Fix opentelemetry-logs-sdk logger does not expose logger_provider, causing NoMethodError on flush/close.
- Fix invalid exception instance causing NoMethodError when retrieving backtrace
- Pin minitest to < 6.0 to avoid breaking changes
- Add `with_level` method to `Base` to allow changing log level during block execution, in analogue to `Logger.with_level`.
- Add event_type to Honeybadger Insights payloads
- Fix StatsD metric appender: negative metric amounts were silently ignored, so the decrement was never sent.
- Fix Syslog formatter raising when `level_map` is supplied as a Hash.
- Remove stray `puts` debug output from the Loki appender.

## [4.17.0]

- Correct `source_code_uri` URL
- Add appender for Grafana Loki using the HTTP push API.
- Add :notime as a time_format for Formatters
- Fix #316: syslog messages contains two timestamps
- Add appender for CloudWatch Logs
- Add appender for Open Telemetry Logs
- NR Integration: Ensures key/values are not nested under `messages`
- NR Integration: Ensures structures are built for all nested json (I.E build an actual object instead of doing `span.id` as the key)
- NR Integration: Named tags will instead be added directly to the JSON.  `named_tags` now adds key value pairs to object instead of nesting.
- NR Integration: Conflicts between `named_tags` and existing tags are logged to `named_tag_conflicts` key.
- NR Integration: Adds a quick and hacky Dockerfile and Docker Compose file to allow for testing changes locally.

## [4.16.1]

- Add Honeybadger and Honeybadger Insights to Appenders doc.
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
    - See [Appenders](https://logger.reidmorrison.com/appenders.html)
    - Move AnsiColors into its own module: `SemanticLogger::AnsiColors`
- Appenders now use the same hash style arguments as `SemanticLogger.add_appender`.
- Appenders use the new common formatters where applicable.
- Appenders now use custom formatters as the `#call` method for better performance over blocks.
- Bugsnag appender will now forward `:fatal` errors, since some were being ignored and
  not being reported in Bugsnag. Changes in [Rails Semantic Logger](https://logger.reidmorrison.com/rails.html)
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
