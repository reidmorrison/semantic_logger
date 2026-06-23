---
layout: default
---

## Security

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

See [Escaping Control Characters](customize.html#escaping-control-characters) for
details.

The record-framed network appenders are already safe by default:

* The **TCP** and **UDP** appenders default to the JSON formatter.
* The **Syslog** formatters escape control characters by default, since syslog frames
  each record.

If you replace the formatter on any of these appenders with a text formatter, enable
`escape_control_chars` as shown above.

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
mutates the log and returns `true`. See [Filtering](filtering.html) for examples.

Rails applications should use the sister gem
[rails_semantic_logger](https://github.com/reidmorrison/rails_semantic_logger), which
honours `config.filter_parameters` so that parameters Rails already considers sensitive
are filtered out of the logs.

### Transport encryption

Appenders that send logs over the network support TLS. The appenders built on the
`:http` appender (`:http`, `:splunk_http`, and `:elasticsearch_http`) default to
verifying the server certificate (`OpenSSL::SSL::VERIFY_PEER`) when an `https` URL is
used.

Do not disable certificate verification in production. Settings such as
`ssl: {verify_mode: OpenSSL::SSL::VERIFY_NONE}` expose the connection to
man-in-the-middle attacks and should be limited to local development against
self-signed certificates.

### Log file permissions

Log files frequently contain sensitive information. By default the file appender
creates files using the process umask, the standard Ruby behavior. To restrict access,
supply the `permissions` option, which is applied both when the file is created and to
an existing log file:

~~~ruby
# Owner read/write, group read, no access for others:
SemanticLogger.add_appender(file_name: "production.log", permissions: 0o640)
~~~

### Dependencies and supply chain

Semantic Logger has a single runtime dependency, `concurrent-ruby`. Appenders for
third-party services (Kafka, MongoDB, Sentry, etc.) keep their backing gem optional: it
is required lazily inside the appender only when that appender is used, and is never
added to the gemspec. This keeps the dependency surface of an application that only uses
the built-in file and IO appenders very small.

Auditing the resolved dependency versions for known advisories is the responsibility of
the consuming application, which should run a tool such as
[bundler-audit](https://github.com/rubysec/bundler-audit) against its own
`Gemfile.lock`. Pinning dependencies with a committed lockfile, and verifying it in CI
with `bundle install --frozen`, prevents an unexpected dependency from being pulled in.

### [Next: Log Event ==>](log_struct.html)
