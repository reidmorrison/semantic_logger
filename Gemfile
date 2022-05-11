source "http://rubygems.org"

gemspec

gem "amazing_print"
gem "minitest"
gem "minitest-reporters"
gem "minitest-shared_description"
gem "minitest-stub_any_instance"
gem "rake"

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
gem "nokogiri"
# [optional] Statsd metrics
gem "statsd-ruby"
# [optional] legacy Sentry appender
gem "sentry-raven"
# [optional] new Sentry appender
gem "sentry-ruby"
# [optional] Syslog appender when communicating with a remote syslogd over TCP
gem "syslog_protocol"

group :development do
  gem "rubocop", "~> 1.28", "< 1.29"
end
