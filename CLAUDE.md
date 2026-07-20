# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Semantic Logger is a Ruby gem: a feature-rich, multi-destination logging framework and replacement for Ruby & Rails loggers. Its defining trait is **asynchronous logging** — log events are pushed onto an in-memory queue serviced by a background thread, so the application is not blocked while logs are written to one or more destinations ("appenders").

Rails users should use the sister gem `rails_semantic_logger`, not this gem directly.

**Sister gem version lockstep:** `rails_semantic_logger` is locked to the same major version of this gem. As of v5 it has been upgraded in lockstep: it is now on v5.0.0 and its gemspec pins `semantic_logger ">= 5.0"`. Major-version changes here must continue to be mirrored there. The v5 internal refactors (the `QueueProcessor` extraction and the removal of `Appender::AsyncBatch`) have been accounted for; the sister gem does not reference `AsyncBatch` directly. The sister gem lives at `/Users/reidmo/src/rails_semantic_logger` (when checked out locally).

## Public interface

The **only** public-facing interface is the `SemanticLogger` module itself ([lib/semantic_logger/semantic_logger.rb](lib/semantic_logger/semantic_logger.rb)): its module methods (`SemanticLogger[...]`, `add_appender`, `default_level=`, `tagged`, `silence`, `flush`, `reopen`, etc.) plus the `Loggable` mixin. Everything else (`Logger`, `Base`, `Processor`, `Subscriber`, `Appender::*`, `Formatters::*`, `Log`, ...) is **internal** and may be refactored freely, as long as the public interface keeps working.

The one wrinkle: once a `Logger` instance has been handed back (via `SemanticLogger['ClassName']` or the `logger` method from `Loggable`), that instance's API (`info`, `measure_info`, `tagged`, `level=`, ...) is also part of the public contract. But end users never need to know *how* a `Logger` is constructed — it is always obtained through the `SemanticLogger` module or the `Loggable` mixin, so the constructor and the class itself remain internal.

When changing internal classes, the bar is: **do not break any existing public-facing interface** (the `SemanticLogger` module methods or a returned `Logger`'s methods).

The Ruby `Logger` compatibility aliases in [lib/semantic_logger/concerns/compatibility.rb](lib/semantic_logger/concerns/compatibility.rb) (`<<`, `add`, `progname`, `sev_threshold`, `silence_logger`, ...) are **not** part of the published public interface. They exist solely so Semantic Logger can stand in for the Ruby/Rails loggers (Rails and libraries like Active Record's session store call them), so they must keep working for that purpose, but do not document, extend, or promote them as public API.

## Commands

```bash
bundle install              # install dependencies
bundle exec rake            # run the full test suite (the default task)
bundle exec rake test       # same as above
bundle exec rubocop         # lint
LOGGER_SYNC=1 bundle exec rake   # run tests in synchronous mode (no background thread)
```

Run a single test file or test:

```bash
bundle exec ruby -Itest test/logger_test.rb
bundle exec ruby -Itest test/logger_test.rb -n /pattern/
```

Some appender tests need MongoDB. CI runs against Ruby 3.2–4.0 with a MongoDB service on `127.0.0.1:27017` (`MONGO_HOST` env var). Use `docker compose up` (see `docker-compose.yaml`) to start a local MongoDB container; the tests themselves run on the host.

The minimum supported Ruby is 3.2 (as of v5; see `gemspec` and `.rubocop.yml`'s `TargetRubyVersion`) — do not use syntax newer than that in `lib/`.

## Architecture

The logging pipeline has four layers. Understanding the hand-off between them is the key to this codebase:

1. **`SemanticLogger::Logger`** ([lib/semantic_logger/logger.rb](lib/semantic_logger/logger.rb)) — what application code holds (one per class, via `SemanticLogger['ClassName']` or the `Loggable` mixin). `logger.info(...)` etc. build a `Log` object and hand it to the global processor. There is **one shared processor** for the whole process (`Logger.processor`), not one per logger.

2. **`SemanticLogger::Base`** ([lib/semantic_logger/base.rb](lib/semantic_logger/base.rb)) — abstract superclass of both `Logger` and `Subscriber`. It metaprograms the per-level methods (`debug`/`info`/`warn`/..., plus `measure_*` and `benchmark_*`) from `Levels::LEVELS`, and contains the argument-parsing logic in `log_internal` / `measure_internal` that turns the flexible call signatures (message, payload hash, exception, block) into a populated `Log`.

3. **`SemanticLogger::Processor`** ([lib/semantic_logger/processor.rb](lib/semantic_logger/processor.rb)) — a singleton that **is** an `Appender::Async`. It owns the background thread and the queue. It fans each `Log` out to the `Appenders` collection. `SyncProcessor` ([lib/semantic_logger/sync_processor.rb](lib/semantic_logger/sync_processor.rb)) is the drop-in replacement used when `SemanticLogger.sync!` is called (or `require "semantic_logger/sync"`), which logs inline on the calling thread — used heavily in tests.

4. **`SemanticLogger::Subscriber`** ([lib/semantic_logger/subscriber.rb](lib/semantic_logger/subscriber.rb)) — the abstract base class for **all appenders** (despite the name). Each appender writes a `Log` to one destination, using its own `Formatter`. Concrete appenders live in [lib/semantic_logger/appender/](lib/semantic_logger/appender/).

### Sync vs. Async layering

`Appender::Async` ([lib/semantic_logger/appender/async.rb](lib/semantic_logger/appender/async.rb)) is a **proxy** that wraps a real appender and runs it in a separate thread with a queue, in either streaming or batched mode. `Appender.factory` ([lib/semantic_logger/appender.rb](lib/semantic_logger/appender.rb)) decides at construction time whether to wrap an appender in `Async` and whether to enable batching (batch is automatic if the appender implements `#batch` and opts in via `#batch_by_default?`, or explicit via `batch: true`). Note the two distinct uses of "async": the global `Processor` is one `Async` (the main pipeline thread), and an *individual* appender can additionally be made async/batched.

The thread + queue machinery itself lives in **`SemanticLogger::QueueProcessor`** ([lib/semantic_logger/queue_processor.rb](lib/semantic_logger/queue_processor.rb)), an internal class that the proxy delegates to. It owns the worker thread, the (capped or uncapped) queue, lag checking, non-blocking drop mode, the processed/dropped counters, and **both** processing loops (streaming vs. batched, switched by `batch?`). `Async` is a thin proxy: it forwards `name`/`level`/`logger`/… to the wrapped appender and `log`/`flush`/`close`/`reopen`/`queue`/`batch?`/`batch_size`/… to its `QueueProcessor`.

There used to be a separate `Appender::AsyncBatch < Async` subclass; it was removed in v5 once batching moved entirely into `QueueProcessor`. `batch: true` now returns a `SemanticLogger::Appender::Async` (with `batch?` true), not an `AsyncBatch`. If you reintroduce a batch-specific proxy, keep the single `QueueProcessor` as the engine rather than duplicating the loops.

**Backward-compat bar for appenders/formatters:** anyone may have written their own `Subscriber`-derived appender or a custom formatter, so treat the appender/formatter contract as public even though the classes are nominally internal. Concretely: an appender's `#log(log)` / `#batch(logs)` / `#flush` / `#close` / `#reopen` / `#should_log?(log)` signatures, the `#batch` + `#batch_by_default?` opt-in mechanism, and a formatter's `#call(log, logger)` signature must keep working unchanged. The `Log` object handed to appenders is **not frozen**: appenders/formatters may continue to read and (historically) mutate it on the worker thread; do not introduce `Log#freeze` on the queue hand-off without a major-version change.

### Factory pattern

`SemanticLogger.add_appender(**args)` is the single public entry point for adding destinations. It delegates to `Appender.factory` → `Appender.build`, which dispatches on the keyword used: `file_name:`, `io:`, `logger:` (wraps an existing Ruby/Rails logger), `appender:` (a Symbol naming a built-in appender, or a `Subscriber` instance), or `metric:`. Formatters are resolved the same way via `Formatters.factory` ([lib/semantic_logger/formatters.rb](lib/semantic_logger/formatters.rb)) — a Symbol like `:json`/`:color`/`:logfmt`, an object responding to `#call`, or a Proc.

To add a new appender or formatter, add the class under the respective directory and register it in the `autoload` list in [lib/semantic_logger/appender.rb](lib/semantic_logger/appender.rb) or [lib/semantic_logger/formatters.rb](lib/semantic_logger/formatters.rb). Appenders for third-party services keep their backing gem **optional** — it is required lazily inside the appender, and listed in the `Gemfile` (for tests) and `README.md`, but never added to the `gemspec`.

### Cross-cutting concepts

- **`Log`** ([lib/semantic_logger/log.rb](lib/semantic_logger/log.rb)) — the immutable-ish value object passed through the whole pipeline. `assign` populates it and can return `false` to suppress logging (e.g. `min_duration` not met). `NON_PAYLOAD_KEYS` controls which keyword args are first-class fields vs. folded into `payload`.
- **Levels** ([lib/semantic_logger/levels.rb](lib/semantic_logger/levels.rb)) — `:trace, :debug, :info, :warn, :error, :fatal`. Comparisons use a pre-computed integer `level_index` for speed; this is a recurring performance pattern, do not replace it with symbol comparisons.
- **Tags & named tags** — thread-local context stored in `Thread.current[:semantic_logger_tags]` / `[:semantic_logger_named_tags]`. The fast paths (`SemanticLogger.tagged`, `.push_tags`, `.fast_tag`) assume clean string tags; the slower instance methods on `Base` flatten/reject-empty for Rails compatibility.
- **`on_log` subscribers** ([lib/semantic_logger/logger.rb](lib/semantic_logger/logger.rb)) — callbacks run **inline on the calling thread** (before the queue hand-off) so they can capture request-scoped context. Keep them fast.
- **Forking** — after `fork`, file handles and the queue must be re-created via `SemanticLogger.reopen` → `Appenders#reopen` → `Async#reopen`. As of v5 this happens automatically: a `Process._fork`/`daemon` hook ([lib/semantic_logger/core_ext/process.rb](lib/semantic_logger/core_ext/process.rb), prepended in [lib/semantic_logger.rb](lib/semantic_logger.rb)) calls `reopen` in the child unless `SemanticLogger.reopen_on_fork = false`. `reopen` is guarded to run once per process (pid-based; bypass with `reopen(force: true)`). `at_exit` in [lib/semantic_logger.rb](lib/semantic_logger.rb) flushes the queue on shutdown.
- **`Loggable`** ([lib/semantic_logger/loggable.rb](lib/semantic_logger/loggable.rb)) — mixin giving a class both `self.logger` and instance `logger`, plus `logger_measure_method` which wraps a method (via a prepended module) to log its duration.

## Testing conventions

- Tests use **Minitest** (spec style), with `minitest-reporters`, `minitest-shared_description`, and `amazing_print` for diffs. [test/test_helper.rb](test/test_helper.rb) is required by every test.
- The standard way to assert on emitted logs is the in-memory appenders ([test/in_memory_appender.rb](test/in_memory_appender.rb) and helpers) — add a capturing appender and inspect the `Log` objects, rather than parsing formatted output.
- For testing application code that uses Semantic Logger, the gem ships `SemanticLogger::Test::CaptureLogEvents` and `SemanticLogger::Test::Minitest` ([lib/semantic_logger/test/](lib/semantic_logger/test/)).
- Appender tests for external services use mocks/fakes (e.g. [test/mocks/](test/mocks/), `test/appender/fake_bunny.rb`) rather than real connections, except MongoDB.

## Docs

User-facing documentation is a Jekyll site under [docs/](docs/) (published to logger.rocketjob.io). When changing public behavior, update the relevant `docs/*.md` page (e.g. `appenders.md`, `metrics.md`, `api.md`, `testing.md`).

The site also serves two files for AI assistants: [docs/llms.txt](docs/llms.txt), a hand-maintained index of the docs pages (update it when adding or renaming a page), and `docs/llms-full.txt`, all pages concatenated, regenerated with `bundle exec rake llms_full`. **After editing any `docs/*.md` page, re-run `bundle exec rake llms_full`** and commit the result; never edit `llms-full.txt` by hand. The `docs/*.md` sources also ship inside the gem package (see `s.files` in the gemspec) so coding agents inside applications can read them locally.

## Known tech debt

Standing items, tracked here so sessions know what is intentional versus worth fixing. Removals or contract changes wait for a major version.

- **Legacy service appenders — remove in v6.** As of v5.1 each emits a deprecation warning (via `Kernel.warn(category: :deprecated)`) but still works: [sentry.rb](lib/semantic_logger/appender/sentry.rb) (EOL `sentry-raven`, superseded by [sentry_ruby.rb](lib/semantic_logger/appender/sentry_ruby.rb)); [new_relic.rb](lib/semantic_logger/appender/new_relic.rb) (error events via `newrelic_rpm`, superseded by [new_relic_logs.rb](lib/semantic_logger/appender/new_relic_logs.rb)). The Elasticsearch/OpenSearch `type:` option is already inert (ignored on all versions, warns when passed); its keyword can be dropped entirely. Remove all three in v6; see the v5.1 upgrade notes in [docs/upgrading.md](docs/upgrading.md).
- **rubocop_todo backlog.** `.rubocop_todo.yml` suppresses 27 cop categories (down from 32; `Layout/LineLength` was restored to the standard `Max: 120` and four cops were cleared in the 5.1 cycle). Treat it as a burn-down list: when touching a file, prefer fixing its suppressed offenses over adding new ones; never add to the todo file. Most of the remainder is complexity metrics (`Metrics/*`) and test-only cops (`Minitest/*`) that need refactoring rather than mechanical fixes.

## Writing style

Replace em dashes (—) in prose, documents, and generated text with commas, colons, parentheses, semicolons, or separate sentences as fits the context.
