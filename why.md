---
layout: default
---

## Why Semantic logging?

Just as there is the initiative to add Semantic information to data on the web
so that computers can directly understand the content without having to resort
to complex regular expressions or machine learning techniques, it is important
to be able to do the same with log files or data.

Semantic Logger allows every log entry to have not only a message, but a payload
that can be written to a file or a NOSQL destination.

Once the logging data is in the NOSQL data store it can be queried quickly and
efficiently. Some SQL data stores also allow complex data types that could be used
for storing and querying the logging data

Before writing SemanticLogger all of the following logging frameworks were thoroughly
evaluated. None of them met the above Semantic requirements, or the performance requirements
of hundreds of threads all logging at the same time:
logback, logging, log4r, central_logger, whoops

## Performance

The traditional logging implementations write their log information to file in the
same thread of execution as the program itself. This means that for every log entry
the program has to wait for the data to be written.

With Semantic Logger it uses a dedicated thread for logging so that writing to
the log file or other appenders does not hold up program execution.

Also, since the logging is in this separate thread there is no impact to program
execution if we decided to add another appender.
For example, log to both a file and a MongoDB collection.

## Architecture & Performance

In order to ensure that logging does not hinder the performance of the application
all log entries are written to thread-safe Queue. A separate thread is responsible
for writing the log entries to each of the appenders.

In this way formatting and disk or network write delays will not affect the
performance of the application. Also adding more than one appender does not affect
the runtime performance of the application.

The logging thread is automatically started on initialization. When the program
terminates it will call flush on each of the appenders.

Calling SemanticLogger::Logger#flush will wait until all outstanding log messages
have been written and flushed to their respective appenders before returning.

