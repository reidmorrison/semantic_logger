---
layout: default
---

## Rails

When using SemanticLogger inside of Rails all we need to do is include the
`rails_semantic_logger` gem and the default Rails logger will be replaced with
Semantic Logger.

### Rails Configuration

When the `rails_semantic_logger` gem is included in a Rails project it automatically replaces the
loggers for Rails, ActiveRecord::Base, ActionController::Base, and ActiveResource::Base
with wrappers that set their Class name. For example in semantic_logger/railtie.rb:

```ruby
ActiveRecord::Base.logger = SemanticLogger[ActiveRecord]
```

By replacing their loggers we now get the class name in the text logging output:

    2012-08-30 15:24:13.439 D [47900:main] ActiveRecord --   SQL (12.0ms)  SELECT `schema_migrations`.`version` FROM `schema_migrations`

## Log Rotation

Since the log file is not re-opened with every call, when the log file needs
to be rotated, use a copy-truncate operation over deleting the file.

Sample Log rotation file for Linux:

```
/var/www/rails/my_rails_app/shared/log/*.log {
        daily
        missingok
        copytruncate
        rotate 14
        compress
        delaycompress
        notifempty
}
```