# Sends a few log entries and metrics to the OpenTelemetry Collector of compose.yml, which writes them
# to ClickHouse. See docs/clickhouse.md.
#
#   bundle exec ruby examples/clickhouse/app.rb
require "bundler/setup"
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "semantic_logger"

SemanticLogger.application = "checkout"
SemanticLogger.environment = "development"
# Log entries, in batches, to http://localhost:4318/v1/logs.
SemanticLogger.add_appender(appender: :otlp)
# Metrics, every 10 seconds, to http://localhost:4318/v1/metrics.
SemanticLogger.add_appender(metric: :otlp, interval: 10)

logger = SemanticLogger["Orders"]

SemanticLogger.named_tagged(request_id: "req-1") do
  logger.info("Created order", order_id: 42, total: 19.99)
  logger.increment("orders.created", dimensions: {plan: "pro"})
  logger.time("orders.charge", dimensions: {gateway: "stripe"}) { sleep(0.02) }
end
logger.warn("Payment retried", attempt: 2)
logger.error(ArgumentError.new("no route matches [GET] /missing"))

# The logs and the metrics recorded so far are sent at exit.
