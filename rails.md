---
layout: default
---

## Rails

By including the `rails_semantic_logger` gem, Rails Semantic Logger will
replace the default Rails logger with Semantic Logger. Without further
configuration it will log to the existing Rails log file in a more efficient
multi-threaded way.

The following built-in Rails logger instances are replaced with Semantic Logger instances
that include the Class name in all their log messages:
Rails, ActiveRecord::Base, ActionController::Base, and ActiveResource::Base

Extract from a Rails log file after adding the semantic_logger gem:

~~~
2012-10-19 12:05:46.736 I [35940:JRubyWorker-10] Rails --

Started GET "/" for 127.0.0.1 at 2012-10-19 12:05:46 +0000
2012-10-19 12:05:47.318 I [35940:JRubyWorker-10] ActionController --   Processing by AdminController#index as HTML
2012-10-19 12:05:47.633 D [35940:JRubyWorker-10] ActiveRecord --   User Load (2.0ms)  SELECT `users`.* FROM `users` WHERE `users`.`id` = 1 LIMIT 1
2012-10-19 12:05:49.833 D [35940:JRubyWorker-10] ActiveRecord --   Role Load (2.0ms)  SELECT `roles`.* FROM `roles`
2012-10-19 12:05:49.868 D [35940:JRubyWorker-10] ActiveRecord --   Role Load (1.0ms)  SELECT * FROM `roles` INNER JOIN `roles_users` ON `roles`.id = `roles_users`.role_id WHERE (`roles_users`.user_id = 1 )
2012-10-19 12:05:49.885 I [35940:JRubyWorker-10] ActionController -- Rendered menus/_control_system.html.erb (98.0ms)
2012-10-19 12:05:51.014 I [35940:JRubyWorker-10] ActionController -- Rendered layouts/_top_bar.html.erb (386.0ms)
2012-10-19 12:05:51.071 D [35940:JRubyWorker-10] ActiveRecord --   Announcement Load (20.0ms)  SELECT `announcements`.* FROM `announcements` WHERE `announcements`.`active` = 1 ORDER BY created_at desc
2012-10-19 12:05:51.072 I [35940:JRubyWorker-10] ActionController -- Rendered layouts/_announcement.html.erb (26.0ms)
2012-10-19 12:05:51.083 I [35940:JRubyWorker-10] ActionController -- Rendered layouts/_flash.html.erb (4.0ms)
2012-10-19 12:05:51.109 I [35940:JRubyWorker-10] ActionController -- Rendered layouts/_footer.html.erb (16.0ms)
2012-10-19 12:05:51.109 I [35940:JRubyWorker-10] ActionController -- Rendered admin/index.html.erb within layouts/base (1329.0ms)
2012-10-19 12:05:51.113 I [35940:JRubyWorker-10] ActionController -- Completed 200 OK in 3795ms (Views: 1349.0ms | ActiveRecord: 88.0ms | Mongo: 0.0ms)
~~~

### Rails Support

* Supports Rails 3, 4, & 5 ( or above )

## Installation

Add the following line to Gemfile

~~~ruby
gem 'rails_semantic_logger'
~~~

Install required gems with bundler

    bundle install

This will automatically replace the standard Rails logger with Semantic Logger
which will write all log data to the configured Rails log file.

## Configuration

### Log Level

By default Semantic Logger will detect the log level from Rails. To set the
log level explicitly, add the following line to
config/environments/production.rb inside the Application.configure block

~~~ruby
config.log_level = :trace
~~~

#### Colorized Logging

If the Rails colorized logging is enabled, then the colorized formatter will be used
by default. To disable colorized logging in both Rails and Semantic Logger:

~~~ruby
config.colorize_logging = false
~~~

### Process Forking

Also see [Process Forking](forking.html) if you use Unicorn or Puma

#### MongoDB logging

To log to both the Rails log file and MongoDB add the following lines to
config/environments/production.rb inside the Application.configure block

~~~ruby
require 'mongo'
config.after_initialize do
  # Re-use the existing MongoDB connection, or create a new one here
  db = Mongo::MongoClient.new['production_logging']

  # Besides logging to the standard Rails logger, also log to MongoDB
  config.semantic_logger.add_appender SemanticLogger::Appender::MongoDB.new(
    db:              db,
    collection_name: 'semantic_logger',
    collection_size: 25.gigabytes
  )
end
~~~

#### Logging to Syslog

Configuring rails to also log to a local Syslog:

~~~ruby
config.after_initialize do
  config.semantic_logger.add_appender(SemanticLogger::Appender::Syslog.new)
end
~~~

Configuring rails to also log to a remote Syslog server such as syslog-ng over TCP:

~~~ruby
config.after_initialize do
  config.semantic_logger.add_appender(SemanticLogger::Appender::Syslog.new(:server => 'tcp://myloghost:514'))
end
~~~

### Log Rotation

Since the log file is not re-opened with every call, when the log file needs
to be rotated, use a copy-truncate operation over deleting the file.

Sample Log rotation file for Linux:

~~~
/var/www/rails/my_rails_app/shared/log/*.log {
        daily
        missingok
        copytruncate
        rotate 14
        compress
        delaycompress
        notifempty
}
~~~

### Custom Appenders and Formatters

The format of data logged by Semantic Logger is specific to each appender.

To change the text file log format in Rails Semantic Logger, create a rails initializer with the following code and customize as needed.
For example: 'config/initializers/semantic_logger_formatter.rb'

~~~ruby
# Replace the format of the existing log file appender
SemanticLogger.appenders.first.formatter = Proc.new do |log|
  tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags && (log.tags.size > 0)

  message = log.message.to_s
  message << " -- " << log.payload.inspect if log.payload
  message << " -- " << "#{log.exception.class}: #{log.exception.message}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

  duration_str = log.duration ? "(#{'%.1f' % log.duration}ms) " : ''

  "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{log.level.to_s[0..0].upcase} [#{$$}:#{log.thread_name}] #{tags}#{duration_str}#{log.name} : #{message}"
end
~~~

### Replacing Existing loggers

Rails Semantic Logger automatically replaces the default logger for the following gems
after they have been initialized:

- Sidekiq
- Resque
- Mongoid
- MongoMapper
- Moped
- Bugsnag

### [Next: API ==>](api.html)
