---
layout: default
title: Security
description: >-
  Keeping logs trustworthy: log injection and forging, redacting sensitive
  data, transport encryption, log file permissions, and the gem's dependency
  footprint.
---


**Contents**

* TOC
{:toc}

Logging frameworks sit on a sensitive boundary: they take data from all over an
application, including data that originated from untrusted users, and write it to
files, terminals, and centralized logging systems. This page describes the security
properties of Semantic Logger and how to configure it when logging untrusted data.

### Log injection and forging

When a log message, tag, or exception message contains untrusted, attacker-controlled
data (for example a user name, request parameter, or `User-Agent` header), control
characters in that data can be abused:

* A newline can forge an additional, fake log entry ("log forging"), or split one
  record into two at a collector that frames records with a separator.
* An ANSI escape sequence can spoof or hide terminal output when the log is viewed in
  a terminal.

The structured formatters, such as `:json`, are **not** affected, because JSON encoding
always escapes control characters. They are the recommended choice when forwarding logs
that may contain untrusted data to a centralized logging system.

By design the human readable text formatters (`:default` and `:color`) preserve
newlines and ANSI color codes, since multi-line and colorized output is useful when
reading logs locally. When the text output may contain untrusted data, enable the
`escape_control_chars` option to replace control characters with a printable, escaped
form (for example a newline becomes `\n`):

~~~ruby
SemanticLogger.add_appender(file_name: "production.log", formatter: {default: {escape_control_chars: true}})
~~~

See [Escaping Control Characters](config.html#escaping-control-characters) for
details.

The record-framed network appenders are already safe by default:

* The **TCP** and **UDP** appenders default to the JSON formatter.
* The **Syslog** formatters escape control characters by default, since syslog frames
  each record.

If you replace the formatter on any of these appenders with a text formatter, enable
`escape_control_chars` as shown above.

### Logging untrusted hashes

A hash passed after the message is the payload, but a few of its keys are also log arguments:
`duration`, `min_duration`, `metric`, `metric_amount`, `exception`, `log_exception`, and so on.
That is convenient for code you write, but when the hash holds untrusted data, such as parsed
request parameters or a webhook body with Symbol keys, it can set those arguments too. For
example `{duration: 0, min_duration: 1}` would suppress the entry.

Semantic Logger only uses such a key as an argument when its value is valid for it: for example
`duration` must be a finite real number, `backtrace` an Array of Strings, and `on_exception_level` a
valid level. Any other value stays in the payload as data, and a `nil` value is ignored, so an
untrusted hash passed to a level method such as `info` can never make the logging call raise.

To make sure none of its keys are treated as arguments, pass it as the explicit `payload:`. Any other
keys supplied alongside an explicit `payload:` are merged into it, and win over the explicit
payload's values of the same name, so that the untrusted data cannot replace a value your code
supplies:

~~~ruby
# The hash is logged as-is, and none of its keys are interpreted. Its own account_id, if any,
# cannot replace the one supplied here:
logger.info("Webhook received", payload: JSON.parse(body, symbolize_names: true), account_id: account.id)
~~~

A hash returned from a logging block, such as
`logger.debug("Webhook received") { JSON.parse(body, symbolize_names: true) }`, is checked the
same way: a key is only used as an argument when its value is valid for it, its `message` only
when the log call supplied none, and its `payload` only when it is a Hash. It never replaces a value
the log call supplied, and the caller's own payload Hash is left unchanged.

The options of a `measure_*` call are checked the same way: an option with a value that is not valid
for it is ignored, and its default is used. Keys that are not measure options are not logged at all,
so pass untrusted data to a measure call as its `payload:` too. A measure call without a block still
raises unless it is given a valid `:duration`.

### Redacting sensitive data

Semantic Logger does not automatically redact secrets or personal information; it logs
the message and payload it is given. Avoid logging passwords, tokens, full credit card
numbers, and similar values in the first place.

When sensitive values can reach the logs indirectly, redact them. A global `on_log`
subscriber runs inline, once per log event, before the event is handed to any appender,
so it can scrub the message or payload for every destination:

~~~ruby
SECRET_KEYS = %i[password token authorization secret].freeze

SemanticLogger.on_log do |log|
  log.payload&.each_key do |key|
    log.payload[key] = "[REDACTED]" if SECRET_KEYS.include?(key)
  end
end
~~~

Redaction can also be applied to a single logger or appender with a `filter` that
mutates the log and returns `true`. See [Filtering](config.html#filtering) for examples.

Rails applications should use the sister gem
[rails_semantic_logger](https://github.com/reidmorrison/rails_semantic_logger), which
honours `config.filter_parameters` so that parameters Rails already considers sensitive
are filtered out of the logs.

### Transport encryption

Appenders that send logs over the network support TLS. The appenders built on the
`:http` appender (`:http`, `:splunk_http`, `:elasticsearch_http`, and `:loki`) default to
verifying the server certificate (`OpenSSL::SSL::VERIFY_PEER`) when an `https` URL is
used. The `:tcp` appender, and the `:syslog` appender over TCP, verify both the certificate
and the host name when `ssl:` is enabled.

The deprecated `:splunk` appender is the exception: its `splunk-sdk-ruby` gem never verifies
the certificate. Use `:splunk_http` instead.

Do not disable certificate verification in production. Settings such as
`ssl: {verify_mode: OpenSSL::SSL::VERIFY_NONE}` expose the connection to
man-in-the-middle attacks and should be limited to local development against
self-signed certificates.

Credentials can be supplied in the url of the HTTP based appenders, for example
`https://user:password@host`, or as a query parameter. They are removed from the url
written to the internal logger when the server rejects a request, and from `#inspect`.

### Log file permissions

Log files frequently contain sensitive information. By default the file appender
creates files using the process umask, the standard Ruby behavior. To restrict access,
supply the `permissions` option, which is applied both when the file is created and to
an existing log file:

~~~ruby
# Owner read/write, group read, no access for others:
SemanticLogger.add_appender(file_name: "production.log", permissions: 0o640)
~~~

The permissions are only applied when the log file name names a regular file directly, not
through a symbolic link, and that file is owned by the process and has a single hard link. A log
file that is a symbolic link (for example to `/dev/stdout`) is still written to, but the
permissions of whatever it points at are left alone, so that a symbolic or hard link planted in a
shared log directory cannot be used to loosen the permissions of another file. The file name is
also checked to still name the file that was opened, so swapping it in between has no effect.
When the permissions are not applied the appender logs a warning, once, giving the reason. Keep
the log directory writable only by the application.

### Dependencies and supply chain

Semantic Logger has two runtime dependencies, `concurrent-ruby` and `logger` (part of
Ruby's standard library until Ruby 4.0 moved it to the bundled gems). Appenders for
third-party services (Kafka, MongoDB, Sentry, etc.) keep their backing gem optional: it
is required lazily inside the appender only when that appender is used, and is never
added to the gemspec. This keeps the dependency surface of an application that only uses
the built-in file and IO appenders very small.

Auditing the resolved dependency versions for known advisories is the responsibility of
the consuming application, which should run a tool such as
[bundler-audit](https://github.com/rubysec/bundler-audit) against its own
`Gemfile.lock`. Pinning dependencies with a committed lockfile, and verifying it in CI
with `bundle install --frozen`, prevents an unexpected dependency from being pulled in.
