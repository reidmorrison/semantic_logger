source "http://rubygems.org"

gemspec

gem "amazing_print"

# @note While this gem is not called directly anywhere, Ruby 3.1.0 breaks
#   without it because the Splunk SDK requires rexml/document for its
#   xml_shim.rb and rexml is no longer a default gem beyond Ruby
#   2.7.5.
gem "rexml"

# [optional] Bugsnag appender
gem "bugsnag"
# [optional] Rabbitmq appender
gem "bunny"
# [optional] Elasticsearch appender
# 7.14 has a breaking API change.
gem "elasticsearch", "~>7.13.0"
# [optional] Graylog appender
gem "gelf"
# [optional] Honeybadger appender
gem "honeybadger"
# [optional] Kafka appender
gem "ruby-kafka"
# [optional] MongoDB appender
gem "mongo"
# [optional] NewRelic appender ( Tests use a mock class )
# gem 'newrelic_rpm'
# [optional] Net::TCP appender
gem "net_tcp_client"
# [optional] Splunk appender
gem "splunk-sdk-ruby"
# [optional] Statsd metrics
gem "statsd-ruby"
# [optional] legacy Sentry appender
gem "sentry-raven"
# [optional] new Sentry appender
gem "sentry-ruby"
# [optional] Syslog appender when communicating with a remote syslogd over TCP
gem "syslog_protocol"

group :development do
  gem "minitest"
  gem "minitest-reporters"
  gem "minitest-shared_description"
  gem "minitest-stub_any_instance"
  gem "rake"
  gem "rubocop"
end
