semantic-logger-ruby
====================

* http://github.com/ClarityServices/semantic-logger-ruby

Feedback is welcome and appreciated :)

### Introduction

SemanticLogger is a Logger that supports logging of meta-data, not only text messages

Machines can understand the logged data without having to use
complex Regular Expressions or other text parsing techniques

SemanticLogger, sits on top of existing logger implementations and can also
be used as a drop in replacement for existing Ruby loggers.
This allows the existing logging to be replaced immediately with the
SemanticLogger Appenders, and over time the calls can be replaced with ones
that contain the necessary meta-data.

Example of current calls:

    logger.info("Queried users table in #{duration} ms, with a result code of #{result}")

For a machine to find all queries for table 'users' that took longer than
100 ms, would require using a regular expression just to extract the table name
and duration, then apply the necessary logic. It also assumes that the text
is not changed and that matches will not be found when another log entry has
similar text output.

This can be changed over time to:

    Rails.logger.info("Queried table",
           :duration => duration,
           :result   => result,
           :table    => "users",
           :action   => "query")

Using this semantic example, a machine can easily find all queries for table
'users' that took longer than 100 ms.

    db.logs.find({"metadata.table":"users", "metadata.action":"query"})

Since SemanticLogger can call existing Loggers, it does not force end-users
to have to adopt a Semantic aware adapter. Although, such adapters create
tremendous value in the problem monitoring and determination processes.

For ease of use each Appender can be used directly if required. It is preferred
however to use the SemanticLogger interface and supply the configuration to it.
In this way the adapter can be changed without modifying the application
source code.

# Future
- Web Interface to view and search log information
- Override the log level at the appender level

# Configuration

The Semantic Logger follows the principle where multiple appenders can be active
at the same time. This allows one to log to MongoDB and the Rails
ActiveResource::BufferedLogger at the same time.

### Dependencies

- Ruby MRI 1.8.7 (or above) Or, JRuby 1.6.3 (or above)
- Optional: Rails 3.0.10 (or above)
- Optional: To log to MongoDB, Mongo Ruby Driver 1.5.2 or above

### Install

  gem install semantic-logger

Development
-----------

Want to contribute to Semantic Logger?

First clone the repo and run the tests:

    git clone git://github.com/ClarityServices/semantic-logger.git
    cd semantic-logger
    jruby -S rake test

Feel free to ping the mailing list with any issues and we'll try to resolve it.

Contributing
------------

Once you've made your great commits:

1. [Fork](http://help.github.com/forking/) semantic-logger
2. Create a topic branch - `git checkout -b my_branch`
3. Push to your branch - `git push origin my_branch`
4. Create an [Issue](http://github.com/ClarityServices/semantic-logger/issues) with a link to your branch
5. That's it!

We are looking for volunteers to create implementations in other languages such as:
* Java, C# and Go

Meta
----

* Code: `git clone git://github.com/ClarityServices/semantic-logger.git`
* Home: <https://github.com/ClarityServices/semantic-logger>
* Docs: TODO <http://ClarityServices.github.com/semantic-logger/>
* Bugs: <http://github.com/reidmorrison/semantic-logger/issues>
* Gems: <http://rubygems.org/gems/semantic-logger>

This project uses [Semantic Versioning](http://semver.org/).

Authors
-------

Reid Morrison :: reidmo@gmail.com :: @reidmorrison

License
-------

Copyright 2011 Clarity Services, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
