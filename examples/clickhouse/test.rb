# Tests the quick start of docs/clickhouse.md: starts compose.yml, runs app.rb, and checks that its log
# entries and metrics arrived in ClickHouse, with the queries of the guide. Run it by hand before a
# release, and after changing compose.yml, otel-collector.yaml, or the OTLP appenders.
#
#   bundle exec ruby examples/clickhouse/test.rb           # stops the stack afterwards
#   KEEP=1 bundle exec ruby examples/clickhouse/test.rb    # leaves it running, to look at in Grafana
#
# With KEEP=1 the stack stays up as the Compose project semantic-logger-clickhouse-test, with Grafana on
# http://localhost:13000. Stop it with:
#
#   docker compose -f examples/clickhouse/compose.yml -p semantic-logger-clickhouse-test down -v
#
# It uses ports of its own (see PORTS), so that it runs beside a stack on the default ones.
require "bundler/setup"
require "json"
require "net/http"
require "open3"

module ClickHouseTest
  DIR     = __dir__
  # The `docker compose` plugin, or else the separate `docker-compose`, as some installs, such as
  # Colima's, have only that.
  PLUGIN  = system("docker", "compose", "version", out: File::NULL, err: File::NULL)
  # A project of its own, so that the test neither stops nor deletes the stack of the quick start.
  COMPOSE = [
    *(PLUGIN ? %w[docker compose] : %w[docker-compose]),
    "-f", File.join(DIR, "compose.yml"), "-p", "semantic-logger-clickhouse-test"
  ].freeze
  WAIT    = 60

  # Ports of their own, so that the test runs beside a stack on the default ones, such as the Rails demo.
  PORTS = {"CLICKHOUSE_PORT" => "18123", "OTLP_PORT" => "14318", "GRAFANA_PORT" => "13000"}.freeze
  ENV_VARS = PORTS.merge("OTEL_EXPORTER_OTLP_ENDPOINT" => "http://localhost:#{PORTS['OTLP_PORT']}").freeze

  module_function

  def run(*command)
    output, status = Open3.capture2e(ENV_VARS, *command)
    raise("#{command.join(' ')} failed:\n#{output}") unless status.success?

    output
  end

  # Returns [Array<Hash>] the rows of the query, from ClickHouse's HTTP interface.
  def query(sql)
    uri          = URI("http://localhost:#{PORTS['CLICKHOUSE_PORT']}/?database=otel&default_format=JSONEachRow")
    request      = Net::HTTP::Post.new(uri)
    request.body = sql
    request.basic_auth("otel", "otel")
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    raise("ClickHouse: #{response.code} #{response.body}") unless response.is_a?(Net::HTTPSuccess)

    response.body.each_line.map { |line| JSON.parse(line) }
  end

  # Returns the rows of the query once the block accepts them, or the last rows after WAIT seconds,
  # raising the last error of the query instead, when it never answered, such as for a mistake in it.
  def wait_for(sql)
    deadline = Time.now + WAIT
    rows     = []
    error    = nil
    until Time.now > deadline
      begin
        rows  = query(sql)
        error = nil
      rescue StandardError => e
        error = e
      end
      return rows if !error && yield(rows)

      sleep 1
    end
    raise(error) if error

    rows
  end

  def check(problems, what, actual, wanted)
    problems << "#{what}: #{actual.inspect}, not #{wanted.inspect}" unless actual == wanted
  end

  def checks
    problems = []
    logs = wait_for(<<~SQL) { |rows| rows.size >= 3 }
      SELECT Body, SeverityText, ScopeName, ServiceName, LogAttributes
      FROM otel_logs WHERE ServiceName = 'checkout' ORDER BY Timestamp
    SQL
    check(problems, "log bodies", logs.map { |row| row["Body"] },
          ["Created order", "Payment retried", "ArgumentError: no route matches [GET] /missing"])
    created = logs.find { |row| row["Body"] == "Created order" } || {}
    check(problems, "scope", created["ScopeName"], "Orders")
    check(problems, "order_id", created.dig("LogAttributes", "order_id"), "42")
    check(problems, "request_id", created.dig("LogAttributes", "request_id"), "req-1")
    failed = logs.find { |row| row["SeverityText"] == "error" } || {}
    check(problems, "exception.type", failed.dig("LogAttributes", "exception.type"), "ArgumentError")

    # A sum without GROUP BY is one row, of 0 until the metric arrives.
    counter = wait_for(<<~SQL) { |rows| rows.first&.fetch("created", 0).to_f.positive? }
      SELECT sum(Value) AS created FROM otel_metrics_sum
      WHERE MetricName = 'orders.created' AND Attributes['plan'] = 'pro'
    SQL
    check(problems, "orders.created", counter.first&.fetch("created"), 1)
    durations = wait_for(<<~SQL) { |rows| rows.first&.fetch("charges", 0).to_i.positive? }
      SELECT sum(Count) AS charges FROM otel_metrics_exponential_histogram
      WHERE MetricName = 'orders.charge' AND Attributes['gateway'] = 'stripe'
    SQL
    check(problems, "orders.charge count", durations.first&.fetch("charges").to_i, 1)
    # The 95th percentile query of the guide: the charge sleeps 20 ms, so within a bucket of 0.02 s.
    p95 = query(<<~SQL).first&.fetch("p95_seconds").to_f
      SELECT quantileExactWeighted(0.95)(
               pow(2, (PositiveOffset + index - 1 + 0.5) * pow(2, -Scale)), count
             ) AS p95_seconds
      FROM otel_metrics_exponential_histogram
      ARRAY JOIN PositiveBucketCounts AS count, arrayEnumerate(PositiveBucketCounts) AS index
      WHERE MetricName = 'orders.charge' AND TimeUnix > now() - INTERVAL 1 HOUR
    SQL
    # The middle of the bucket that holds 20 ms can be just below it.
    problems << "orders.charge p95 is #{p95} s, not about 0.02 s" unless p95.between?(0.019, 0.05)
    problems
  end

  # Waits until the Collector answers OTLP/HTTP, since its image has nothing for a health check to run,
  # so `up --wait` returns once it has started, maybe before it listens, and Docker's port forwarder
  # accepts a connection before then; app.rb sends at exit, when an entry that cannot be sent is not sent
  # again. An empty request is a valid one, of no records.
  def wait_for_collector
    uri      = URI("http://localhost:#{PORTS['OTLP_PORT']}/v1/logs")
    deadline = Time.now + WAIT
    begin
      response = Net::HTTP.post(uri, "{}", "Content-Type" => "application/json")
      raise(IOError, "answered #{response.code} #{response.body}") unless response.is_a?(Net::HTTPSuccess)
    rescue SystemCallError, IOError, Net::ReadTimeout, Net::OpenTimeout => e
      raise("The Collector does not answer on #{uri}: #{e.message}") if Time.now > deadline

      sleep 1
      retry
    end
  end

  def main
    # From an empty database, without the rows of an earlier run kept with KEEP=1.
    run(*COMPOSE, "down", "-v")
    run(*COMPOSE, "up", "-d", "--wait")
    wait_for_collector
    run("bundle", "exec", "ruby", File.join(DIR, "app.rb"))
    problems = checks
    puts problems.empty? ? "PASS" : problems.map { |problem| "FAIL #{problem}" }
    exit(problems.empty? ? 0 : 1)
  ensure
    cleanup unless ENV["KEEP"]
  end

  # Stops the test's stack, reporting rather than raising a failure, so that the run's own result stands.
  def cleanup
    run(*COMPOSE, "down", "-v")
  rescue RuntimeError => e
    warn("Could not stop the test's stack: #{e.message}")
  end
end

ClickHouseTest.main if $PROGRAM_NAME == __FILE__
