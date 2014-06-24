---
layout: default
---

## Introduction

Semantic Logger is a Logger that supports logging of meta-data, along with text messages
to multiple appenders

An appender is a Logging destination such as a File, MongoDB collection, etc..
Multiple Appenders can be active at the same time. All log entries are written
to each appender.

Machines can understand the logged data without having to use
complex Regular Expressions or other text parsing techniques

Semantic Logger, sits on top of existing logger implementations and can also
be used as a drop in replacement for existing Ruby loggers.
This allows the existing logging to be replaced immediately with the
Semantic Logger Appenders, and over time the calls can be replaced with ones
that contain the necessary meta-data.

Example of current calls:

```ruby
logger.info("Queried users table in #{duration} ms, with a result code of #{result}")
```

For a machine to find all queries for table 'users' that took longer than
100 ms, would require using a regular expression just to extract the table name
and duration, then apply the necessary logic. It also assumes that the text
is not changed and that matches will not be found when another log entry has
similar text output.

This can be changed over time to:

```ruby
logger.info('Queried table',
  duration: duration,
  result:   result,
  table:    'users',
  action:   'query')
```

Using the MongoDB appender, we can easily find all queries for table 'users'
that took longer than 100 ms:

```javascript
db.logs.find({
  "payload.table":"users",
  "payload.action":"query",
  "payload.duration":{$gt:100}
})
```

Since Semantic Logger can call existing Loggers, it does not force end-users
to have to adopt a Semantic aware adapter. Although, such adapters create
tremendous value in the problem monitoring and determination processes.
