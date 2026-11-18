---
layout: default
title: Operations
description: >-
  Running Semantic Logger in production: process forking, log rotation, tuning
  the background pipeline, Linux signals, and shipping to a centralized
  system.
---


**Contents**

* TOC
{:toc}

This page covers running Semantic Logger in production: keeping logging alive across process forks,
rotating log files, tuning the background pipeline, controlling a running process with signals, and
shipping logs to a centralized system. The defaults are good for most applications, so reach for
these topics when you have a specific operational need.

For first-time setup (global settings, appenders, formatters, and filtering), see
[Configuration](config.html).

## Process forking

Frameworks such as Puma, Unicorn, and Resque **fork** the process: they start a worker by cloning the
parent. A forked child does not inherit a working copy of the parent's log file handles or background
thread, so unless those are re-opened in the child, logging quietly stops.

### It is automatic (default)

As of v5 you do not need to do anything. Semantic Logger installs a `Process._fork` hook (Ruby 3.1
and later) that calls `SemanticLogger.reopen` in the child after `fork`, `Process.daemon`,
`IO.popen`, `Kernel#system`, and backticks. That covers every forking framework (Puma, Unicorn,
Resque, Spring, Phusion Passenger, parallel tests, and so on).

`reopen` runs only once per process after a fork, so it is safe even if something else also calls it.

Each appender is reopened by the thread that writes its entries, before it writes the next one, so
that an appender is never reopened while it is writing (see [Reopen manually](#reopen-manually)).
After a fork, that is the child's own thread, which reopens the appender before it writes anything.

In the child, the appenders that keep a connection open to their server leave the one they inherited
to the parent, without closing it or writing to it, and connect again: `:http` and the appenders
built on it (`:elasticsearch_http`, `:splunk_http`, `:loki`, and `metric: :signalfx`), `:tcp`,
`:syslog` and `:graylog` over TCP, and `:kafka`. Closing a TLS connection sends the server a
`close_notify`, which ends the connection for the parent too, and over TLS the server cannot read
what the parent writes after the child has written to it. When one of them cannot connect in the
child, such as while its server cannot be reached, it connects before it writes the next entry.
(`:kafka` connects only when it delivers; when it cannot build a new producer in the child, such as
for invalid options, logging to it raises `IOError` until it is reopened.)

An appender that cannot be reopened, such as `:udp` once its server's name no longer resolves, or
`:http` while its server cannot be reached, is reported to the internal logger, as
`Failed to re-open appender`, or `Async: Failed to reopen the appender` for one added with
`async: true` or in batches, and carries on with what it had, apart from a connection inherited from
the parent (see above). The other appenders are still reopened, and the thread that writes the
entries of an appender added with `async: true` or in batches is still started in the child, so its
entries are written, or discarded and counted like any other entry it cannot write (see
[Retry a failing appender](#retry-a-failing-appender)), rather than left on its queue.

### Reopen manually

You only need the steps below if you turned the automatic hook off, or you rotated logs in a way that
did not fork (see [Log rotation](#log-rotation)).

1. Disable the automatic hook during boot, if you want full manual control:

   ~~~ruby
   SemanticLogger.reopen_on_fork = false
   ~~~

2. Call `reopen` yourself after each fork, or after an in-process log rotation. Within the same
   process, pass `force: true` to bypass the once-per-process guard:

   ~~~ruby
   SemanticLogger.reopen              # after a fork
   SemanticLogger.reopen(force: true) # same process, e.g. after external log rotation
   ~~~

   Within the same process, `reopen` keeps the log entries that are still queued, and the thread
   that writes them keeps running. That thread is only started again if it has stopped, such as
   after `async_max_retries`. After a fork, the child starts with an empty queue, since the parent
   process writes the entries it had queued.

   `reopen` only asks for the appenders to be reopened: each one is reopened by the thread that
   writes its entries, before it writes the next one, so that a file is never closed, nor a
   connection ended, while an entry is being written to it. So `reopen` returns before the appenders
   have reopened; a `SemanticLogger.flush` after it returns once they have. An appender added in
   batches reopens before its next batch, which it writes at most `batch_seconds` later, or when it
   is flushed. An entry still queued when `reopen` is called can be written after the reopen, such
   as to the new log file. That also lets `reopen` be called from a signal trap, such as one that a
   log rotation tool signals, since no appender connects or locks anything there. In synchronous mode
   (see [Synchronous operation](#synchronous-operation)), `reopen` reopens on the calling thread each
   appender that has no thread of its own, so it cannot be called from a signal trap; an appender
   added with `async: true` or in batches is still reopened by its own thread.

You might opt out if another library forks in ways you do not want to trigger a reopen, or you need
to control exactly when the appender thread restarts.

## The json gem's warning about binary text

json 2.8.0 through 3.0.x print this warning each time they serialize a binary String that holds
UTF-8, such as a response body or Base64-decoded text:

```
warning: JSON.generate: UTF-8 string passed as BINARY, this will raise an encoding error in json 3.0
```

Semantic Logger writes such text as UTF-8 with every json version, so with those versions it
prepends a module to Ruby's `Warning` when it is loaded. The module drops this one warning when it
comes from Semantic Logger serializing log data. Every other warning is passed on, and so is this
one from the application's own JSON, including JSON that an exception's `#message` builds. A
module that the application prepends to `Warning` after loading Semantic Logger, such as a test
helper that raises on warnings, sees the warning first. The module is not installed with json 3.1
and later, which raise on such a String instead (Semantic Logger then writes a converted copy),
or on JRuby.

## Payload text where no locale is set

Where no UTF-8 locale is set, as in cron jobs, many container images, and systems with no locale
configured (`LC_ALL`, `LC_CTYPE`, and `LANG` unset, or set to `C` or `POSIX`), CRuby's default
external encoding is US-ASCII. The text formatters (`:default`, `:color`, `:one_line`, `:syslog`,
and `%{payload}` in `:pattern`) write the payload with Ruby's `#inspect`, which then writes each
character outside ASCII as an escape:

```
2026-11-16 09:10:53.874476 I [86699:1312] Checkout -- José -- {name: "Jos\u00E9"}
```

The message, tags, and named tags whose values are Strings are written as they are. A named tag
whose value is an Array or a Hash is written with `#inspect`, and so is escaped as the payload is.
The JSON formatters are not affected, and neither are Rails applications, since Rails sets the
default external encoding to UTF-8 (`config.encoding`), nor JRuby, whose default is UTF-8.

To write these characters, run Ruby with a UTF-8 locale or default external encoding, for example:

```shell
export LC_ALL=C.UTF-8
# or
export RUBYOPT=-Eutf-8
```

or set `Encoding.default_external = Encoding::UTF_8` when the application starts. `LC_ALL`, then
`LC_CTYPE`, take precedence over `LANG`, so setting `LANG=C.UTF-8` is not enough when either is set
to `C` or `POSIX`.

## Log rotation

For performance the log file is **not** re-opened on every write, so a log file must be rotated with
a **copy-truncate** strategy (copy the file aside, then truncate the original in place). Deleting or
renaming the file would leave Semantic Logger writing to a handle that no longer points at the live
file.

Linux's `logrotate` does this well. To set it up:

1. Create a config file for your application, for example `/etc/logrotate.d/my_app`.
2. Point it at your log directory and include `copytruncate`. For daily rotation:

   ~~~
   /var/www/rails/my_app/log/*.log {
           daily
           missingok
           copytruncate
           rotate 14
           compress
           delaycompress
           notifempty
   }
   ~~~

   Or, to rotate by size for very high volume logging:

   ~~~
   /var/www/rails/my_app/log/*.log {
           size 2G
           missingok
           copytruncate
           rotate 7
           compress
           nodelaycompress
           notifempty
           dateformat .%Y%m%d
   }
   ~~~

Other rotation tools work too, as long as they use copy-truncate. If your tool cannot copy-truncate
and instead moves the file, reopen the handles in-process afterwards with
`SemanticLogger.reopen(force: true)` (see [Process forking](#process-forking)).

## Performance and reliability tuning

Every logger hands its events to one shared background thread through an in-memory queue. That thread
writes each event to every appender in turn, so the call to `logger.info` returns immediately. The
knobs below tune that pipeline. The defaults suit most applications; reach for a knob when you have a
specific throughput, availability, or reliability requirement.

### Drop messages instead of blocking

By default the queue is capped (`max_queue_size`, default `10,000`). When it fills (for example
because an appender cannot keep up), `logger.info` **blocks** until there is room, guaranteeing no
message is lost at the cost of briefly slowing the application.

There are two places a slow appender can hold up the application, and a `non_blocking` setting for
each.

**A slow appender that runs on its own thread.** An appender added with `async: true` (or a batching
appender) has a second queue of its own, between the main queue and that appender. Set
`non_blocking: true` on it so that, once its own queue is full, messages for that appender are
**dropped** instead of holding up the main thread:

~~~ruby
SemanticLogger.add_appender(
  file_name:                      "production.log",
  async:                          true,
  non_blocking:                   true,
  dropped_message_report_seconds: 60
)
~~~

The main thread never waits on that appender, so the main queue keeps draining and every other
appender still receives every message. Prefer this when you know which appender is slow, such as one
that writes to a remote service. Dropped messages are counted and reported to the internal logger at
most once every `dropped_message_report_seconds` (default `30`), and appear as `dropped` for that
appender in `SemanticLogger.stats[:appenders]`.

**Everything else.** The main queue still fills if an appender that is not async slows down (for
example `io: $stdout` writing to a pipe that is not being read), or if the main thread cannot keep up
with the volume of messages. Set `SemanticLogger.non_blocking = true` so that messages are
**dropped** instead of blocking `logger.info` once the main queue is full:

~~~ruby
SemanticLogger.non_blocking = true
~~~

This can be set at any time, before or after appenders are added. Dropped messages are reported to
the internal logger at most once every 30 seconds, and the count is available from
`SemanticLogger.stats[:dropped]`. It is not supported in synchronous mode (`SemanticLogger.sync!`),
which has no queue.

When the queue is full, a message logged in a signal trap, such as by the handlers of
[`add_signal_handler`](#linux-signals), is dropped, counted, and reported the same way, with the
report made just after the trap rather than in it.

Either setting keeps logging calls from blocking; neither makes `SemanticLogger.flush` return sooner.
A flush, including the one that runs automatically when the process exits, still waits for every
message already on the queue to be written, unless the destination of an appender added with
`async: true` or in batches fails meanwhile (see [Retry a failing appender](#retry-a-failing-appender)).

`non_blocking` applies only to a capped queue. An uncapped queue (`max_queue_size: -1`) never blocks
and never drops, but can grow without bound.

### Retry a failing appender

If an appender raises while the worker thread is writing, the thread logs the error and restarts, so
a transient failure (such as a brief network blip to a remote appender) does not permanently stop
logging. Each restart sleeps with an increasing back-off (1 second, then 2, ...), reset as soon as a
message is processed successfully. The messages logged meanwhile wait on the queue.

When the appender says that the write that failed wrote none of the message (or, when batching, of
the batch), and is worth trying again, the thread writes the same message or batch again after the
back-off, ahead of the messages on the queue. Once the destination has answered it with a failure
after it was written again 3 times, it is discarded, and the thread carries on with the next one
once it has backed off, so that a message the destination fails every time does not hold up the
others until the thread gives up. A write that never reached the destination, such as one that
could not connect, is not counted, so an outage loses no messages until the thread gives up. The
HTTP based appenders say so for a `408`, `429`, or `503` response, and for a request they could not
send because they could not connect to the server; see
[When the server does not accept a request](appenders.html#when-the-server-does-not-accept-a-request).
Otherwise the message or batch is discarded straight away, since writing it again could write some
of it twice, or would fail the same way, and the thread carries on with the next one once it has
backed off.

A message that fails because of its own content, rather than the destination, is discarded and the
thread carries on straight away, without backing off: for example a value the formatter cannot
serialize (a `JSON::GeneratorError`, `JSON::NestingError`, encoding error, or `FloatDomainError`).
When batching with an appender that sends the whole batch in a single request, such as the HTTP,
Loki, Splunk HTTP, Elasticsearch, and OpenSearch appenders, only that message is discarded and the
rest of the batch is still written. With an appender that may have written part
of the batch before failing, the whole batch is discarded, so that no message is written twice.

A message that fails with an error that writing it again cannot fix, such as a request the
destination refuses for its credentials or its url, is discarded straight away too, without backing
off, as one that fails because of its content. When the appender says that such an error would fail
any batch, whatever it holds, as the HTTP based appenders do for a `401`, `403`, or `404`, the whole
batch is discarded at once, rather than split up to find the messages at fault.

Whether its content or the destination was at fault, the first discarded message is reported to the
internal logger straight away, with its error. After that, the number discarded is reported, with the
latest error, at most once every `dropped_message_report_seconds` (default `30`). The total appears
as `failed` for that appender in `SemanticLogger.stats[:appenders]`.

A `JSON::ParserError`, such as from a destination that answered with an HTML error page, is a
problem with the destination, so the thread backs off as for any other error. The appender decides
which errors are caused by message content; see [Custom appenders](config.html#custom-appenders).
The HTTP based appenders decide by the status of the response; see
[When the server does not accept a request](appenders.html#when-the-server-does-not-accept-a-request).

After `async_max_retries` (default `100`) consecutive failed restarts the worker thread gives up,
rather than spinning forever on a persistent failure, and discards the message or batch it was
writing again. From then on new log messages for that
appender are dropped once its queue is full, instead of blocking the application. So is a message
already waiting for room on the full queue when the thread gives up, within a second, which lets the
thread that logged it carry on: normally the thread that writes to every appender. The messages
already on the queue are kept, and the dropped ones are counted as `dropped` for that appender in
`SemanticLogger.stats[:appenders]`:

~~~ruby
SemanticLogger.add_appender(
  appender:          :http,
  url:               "https://example.com/log",
  async:             true,
  async_max_retries: 20
)
~~~

Set `async_max_retries: -1` to retry indefinitely. The back-off still applies and still resets after
a successful message. `SemanticLogger.reopen(force: true)` starts a worker thread that gave up again,
which writes the messages kept on the queue. It carries on with the count of failed retries: one
that gave up after all `async_max_retries` gives up again at its first failure while the destination
is still unavailable, rather than hold up logging with a back-off as long again, and one that stopped
before using them all, such as after a fatal exception, has only the retries it had left. Once a
message is written, the count starts again. After a fork, the worker thread of the child process
starts counting afresh.

A flush or close does not wait out the back-offs of the worker thread, nor for each message ahead of
it to fail in turn. Submitting one ends the back-off under way, and until it has run, a message or
batch that the destination fails is discarded, and counted as `failed`, rather than written again
after a back-off. So is every message queued after that one, ahead of the flush or close, without
being written: during an outage, each would take as long to fail as the first, such as up to the
`open_timeout` (2 seconds by default) of an HTTP based appender whose server does not answer, or
longer for an appender that retries on its own, such as `:tcp` with its `connect_retry_count`. Those
failures do not count towards `async_max_retries`. Once the flush or close has run, the messages
queued after it are written as usual. A flush still waits while the first message is tried, and
while a destination that takes the messages writes every one of them.

When the process exits, Semantic Logger flushes every appender. Before that flush, it tells each
appender added with `async: true` or in batches that the process is exiting, and each one then acts
as though a flush were already waiting: it stops backing off and writing again what failed, and once
a write fails because of its destination, discards and counts the rest of its queue, without sending
it. Each one is told directly, rather than through the queue of the thread that writes to every
appender, since that thread can be held up handing a message to the full queue of an appender that
is backing off, and so would reach the flush only once that appender stopped backing off. So during
an outage the process exits within seconds, the time one write takes to fail, rather than minutes or
hours, and an appender whose destination takes the messages still writes every one of them. A
`SemanticLogger.flush` called while the process runs reaches each appender through that thread,
behind the messages logged before it.

A flush or close is never left waiting on a worker thread that cannot answer it. When a batch cannot
be written, a flush or close taken off the queue with it still runs before the thread backs off; a
close then stops the thread instead of restarting it. If the worker thread ends without answering,
for example once it gives up, `SemanticLogger.flush` (including the flush at exit) stops waiting on
that appender.

### Give a slow appender its own thread

If one destination is slow, such as a remote HTTP service, run just that appender on its own thread
and queue so it cannot hold up the others:

~~~ruby
SemanticLogger.add_appender(appender: :http, url: "https://example.com/log", async: true)
~~~

### Monitoring the background thread

The background thread can occasionally fall behind, for example when an appender is slow or a sudden
burst of logging occurs. Check the queue at runtime:

~~~ruby
# Number of log entries still waiting to be written
SemanticLogger.queue_size
~~~

For a fuller operational picture, including per-appender queues, use `SemanticLogger.stats`. It
returns a Hash describing the main pipeline and every appender, handy for exporting Semantic Logger's
own health to a monitoring system such as Prometheus or statsd:

~~~ruby
SemanticLogger.stats
# => {
#      queue_size:     0,       # entries waiting on the main pipeline queue
#      capped:         true,    # whether the main queue has a maximum size
#      max_queue_size: 10_000,  # nil when uncapped
#      thread_active:  true,    # whether the main pipeline thread is running
#      processed:      1_532,   # cumulative entries processed since startup
#      dropped:        0,       # cumulative entries dropped at the main queue
#      appenders: [
#        { name: "SemanticLogger::Appender::File", async: false },
#        { name:           "SemanticLogger::Appender::Http",
#          async:          true,    # this appender has its own thread and queue
#          thread_active:  true,
#          queue_size:     3,
#          capped:         true,
#          max_queue_size: 10_000,
#          processed:      1_529,
#          dropped:        0,
#          failed:         0 }  # discarded because they could not be written
#      ]
#    }
~~~

The `processed`, `dropped`, and `failed` counters are cumulative since process startup. Reading `stats` is
thread-safe and adds no locking to the logging hot path.

Semantic Logger also warns when an entry has waited on the queue too long. Tune the threshold and how
often it is checked:

~~~ruby
# Warn when an entry has been on the queue longer than this many seconds ( default: 30 )
SemanticLogger.lag_threshold_s

# Number of messages to process between lag checks ( default: 1,000 )
SemanticLogger.lag_check_interval = 1_000
~~~

If a sustained burst is overwhelming logging, reduce the volume by raising the log level, reduce the
number of appenders, or speed up the slow appender.

### Synchronous operation

Synchronous mode bypasses the background thread and logs inline on the calling thread. This disables
a core design principle of Semantic Logger and slows the calling thread, so it is not recommended for
most applications. It can suit short-lived or single-threaded programs, or forked environments where
you would rather not re-create the logging thread.

Enable it **before** adding any appenders:

~~~ruby
SemanticLogger.sync!
~~~

To guarantee it is set early enough, replace the require with the synchronous variant:

~~~ruby
require "semantic_logger/sync"
~~~

Or, in a Gemfile:

~~~ruby
gem "semantic_logger", require: "semantic_logger/sync"
~~~

## Linux signals

On Linux, Unix, and Mac, Semantic Logger can respond to signals, for example to change the log level
of a running process without restarting it. It registers no signal handlers on startup, so as not to
interfere with any your application already uses.

**Step 1: enable signal handling** during boot:

~~~ruby
# config/initializers/semantic_logger.rb, or during startup of a standalone app
SemanticLogger.add_signal_handler
~~~

**Step 2: send the signal** you need. The capabilities are below.

### Change the log level (USR2)

Send `SIGUSR2` to rotate the global default level, without restarting. Each signal moves the level
one step through this sequence, wrapping from `:trace` back to `:fatal`:

    :fatal  :error  :warn  :info  :debug  :trace

~~~
kill -SIGUSR2 1234
~~~

This changes only the global default level. Loggers whose level was set explicitly in the application
are unaffected.

### Dump all threads (TTIN)

Send `TTIN` to write every thread, with its backtrace where available, to the log. Naming your
threads (`Thread.current.name = "My Worker"`) makes the dump far more useful:

~~~
kill -TTIN 1234
~~~

On JRuby this differs from the standard `QUIT`-triggered Java thread dump, which includes system
threads and Java stack traces.

### JRuby garbage collection logging

On JRuby, any garbage collection that takes longer than 100ms is logged as a warning to the regular
appenders, giving visibility into GC pauses that could affect active requests.

### Choose your own signals

Pass different signals, or set one to `nil` to skip it. Set the GC threshold to `nil` to skip the
JRuby garbage collection logging:

~~~ruby
# Log level change on USR1, thread dump on USR2, GC threshold of 100,000 micro-seconds
SemanticLogger.add_signal_handler("USR1", "USR2", 100000)
~~~

## Centralized logging

Once you run more than one process or server, reading log files one at a time stops scaling. A
**centralized logging** system collects the events from every process into one place where you can
search, filter, and build dashboards across all of them at once. This is where Semantic Logger's
structured output pays off: the payload, tags, duration, and metrics on each entry arrive as real
fields, not text that has to be re-parsed.

This walks through one popular stack end to end as a concrete example:

* **Semantic Logger** forwards structured events from your application.
* **Elasticsearch** stores and indexes them.
* **Kibana** provides search and dashboards on top of Elasticsearch.

The same shape applies to other aggregators (Graylog, Splunk, Loki, Logstash, Syslog). See
[Other destinations](#other-destinations) and [Appenders](appenders.html).

### Step 1: Run Elasticsearch and Kibana

Install and start both. Any installation method works; these notes use
[homebrew](https://brew.sh) on macOS, follow the product links for other platforms.

~~~
brew install elasticsearch
brew install kibana
~~~

Start each one (follow the on-screen instructions to auto-start them), and confirm Elasticsearch is
reachable, by default at `http://localhost:9200`, and Kibana at `http://localhost:5601`.

### Step 2: Forward your application's logs

Add the Elasticsearch appender so Semantic Logger ships every entry to Elasticsearch. In a Rails app
using [rails_semantic_logger](rails.html), put this in an initializer; otherwise add it where you
configure Semantic Logger at startup:

~~~ruby
SemanticLogger.add_appender(
  appender: :elasticsearch,
  url:      "http://localhost:9200"
)
~~~

By default entries are written to a daily index named `semantic_logger-YYYY.MM.DD`, so the index
pattern to search in Kibana is `semantic_logger-*`. See [Elasticsearch](appenders.html#elasticsearch)
for options such as a custom index name or data streams.

Restart the application and exercise it so it generates a few log entries. If nothing appears later,
check the application's own log (for example `log/development.log`) for connection errors.

### Step 3: View the logs in Kibana

1. Open Kibana at [http://localhost:5601](http://localhost:5601).
2. Create an **index pattern** (called a "data view" in newer Kibana versions) that matches
   `semantic_logger-*`.
3. When asked for the time field, choose `timestamp`.
4. Open **Discover**. Your application's log entries appear. If the list is empty, widen the time
   range in the top right.
5. Add a few columns so each entry is readable at a glance, for example `host`, `level`, `name`, and
   `message`.

The exact menu names vary between Kibana versions, but the three things you need are always the same:
an index pattern of `semantic_logger-*`, a time field of `timestamp`, and the Discover view.

### Step 4: Search

In Discover, query against the structured fields directly. A few examples:

~~~
# Only error level entries
level: error

# Only entries from one host
host: mymachine

# Find a value in the logging tags
tags: 17262353
~~~

Because the payload, tags, and metrics are real fields, you can filter and build dashboards on them
without writing log-parsing expressions.

### Other destinations

Elasticsearch and Kibana are just one option. Semantic Logger also forwards to other centralized
logging systems and aggregators, including:

* Logstash
* Graylog
* Splunk
* Grafana Loki
* Loggly
* Syslog

See [Appenders](appenders.html) to configure any of these as a destination.
