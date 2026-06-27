---
layout: default
---

## Operations
{:.no_toc}

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

You might opt out if another library forks in ways you do not want to trigger a reopen, or you need
to control exactly when the appender thread restarts.

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

When availability matters more than complete logs, set `non_blocking: true` so that messages are
**dropped** instead of blocking once the queue is full:

~~~ruby
SemanticLogger.add_appender(
  file_name:    "production.log",
  async:        true,
  non_blocking: true
)
~~~

Dropped messages are counted and reported at most once every `dropped_message_report_seconds`
(default `30`) so they do not go unnoticed:

~~~ruby
SemanticLogger.add_appender(
  file_name:                      "production.log",
  async:                          true,
  non_blocking:                   true,
  dropped_message_report_seconds: 60
)
~~~

`non_blocking` applies only to a capped queue. An uncapped queue (`max_queue_size: -1`) never blocks
and never drops, but can grow without bound.

### Retry a failing appender

If an appender raises while the worker thread is writing, the thread logs the error and restarts, so
a transient failure (such as a brief network blip to a remote appender) does not permanently stop
logging. Each restart sleeps with an increasing back-off (1 second, then 2, ...), reset as soon as a
message is processed successfully.

After `async_max_retries` (default `100`) consecutive failed restarts the worker thread gives up,
rather than spinning forever on a persistent failure:

~~~ruby
SemanticLogger.add_appender(
  appender:          :http,
  url:               "https://example.com/log",
  async:             true,
  async_max_retries: 20
)
~~~

Set `async_max_retries: -1` to retry indefinitely. The back-off still applies and still resets after
a successful message.

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
#          dropped:        0 }
#      ]
#    }
~~~

The `processed` and `dropped` counters are cumulative since process startup. Reading `stats` is
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
