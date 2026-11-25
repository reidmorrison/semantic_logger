# Tests filelog.yaml and filelog.alloy with each agent, and otlp_json_file.yaml with the Collector, in
# Docker: writes a log file with Semantic Logger's :json formatter, and one with :otlp_json_lines, has
# each agent read one with the published configuration and send what it read over OTLP/HTTP to an
# OpenTelemetry Collector that writes it to a file, then checks each record.
#
#   bundle exec ruby examples/filelog/test.rb                # every agent
#   bundle exec ruby examples/filelog/test.rb alloy ddot     # some of them
#
# Needs Docker, and the images below, which it pulls when they are missing. Run it by hand before a release, and
# after changing either configuration or the :json formatter.
require "bundler/setup"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require "opentelemetry-api"
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "semantic_logger"

# Reads the records that the sink received, and checks them against the entries logged.
module Records
  module_function

  # Returns [Array<Hash>] each record the sink received, with its resource and scope.
  def received(out)
    path = File.join(out, "received.json")
    return [] unless File.exist?(path)

    File.readlines(path).flat_map do |line|
      request = parse(line)
      next [] unless request

      request.fetch("resourceLogs", []).flat_map do |resource_logs|
        resource = attributes(resource_logs.dig("resource", "attributes"))
        resource_logs.fetch("scopeLogs", []).flat_map do |scope_logs|
          scope_logs.fetch("logRecords", []).map do |record|
            record.merge("resource" => resource, "scope" => scope_logs.dig("scope", "name"))
          end
        end
      end
    end
  end

  # Returns [Hash|nil] the request on the line, nil for a line that the sink is still writing.
  def parse(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  def attributes(list)
    (list || []).to_h { |kv| [kv["key"], any_value(kv["value"])] }
  end

  def any_value(value)
    return nil unless value

    if value.key?("kvlistValue") then attributes(value.dig("kvlistValue", "values"))
    elsif value.key?("arrayValue") then (value.dig("arrayValue", "values") || []).map { |item| any_value(item) }
    # An Integer, as OTLP/JSON writes an int64 as text, so that a value read as a double is told apart.
    elsif value.key?("intValue") then Integer(value["intValue"])
    else
      value.values.first
    end
  end

  SEVERITY = {"debug" => 5, "info" => 9, "warn" => 13, "error" => 17}.freeze

  # Returns [Array<String>] what is wrong with the records received.
  def check(records, entries, otlp: false)
    problems = []
    by_body  = records.to_h { |record| [record.dig("body", "stringValue"), record] }
    unless otlp
      FilelogTest::OTHER_LINES.each do |line|
        problems << "the line #{line} lost its text" unless by_body.key?(line)
      end
    end
    entries.each do |message, entry|
      # An exception logged without a message is the body, as :otlp writes it.
      exception = entry["exception"]
      record    = by_body[message || (exception && "#{exception['name']}: #{exception['message']}")]
      label     = if message.to_s.empty?
                    "(#{message ? 'empty' : 'no'} message, #{exception&.fetch('name')})"
                  else
                    message
                  end
      next problems << "#{label}: not received" unless record

      check_record(problems, label, record, entry)
      attrs = attributes(record["attributes"])
      expect(problems, label, "thread.name", attrs["thread.name"], entry["thread"])
      if otlp
        check_otlp_attributes(problems, label, attrs, entry)
      else
        check_json_attributes(problems, label, attrs, entry)
      end
    end
    problems
  end

  def expect(problems, message, what, actual, wanted)
    problems << "#{message}: #{what} is #{actual.inspect}, not #{wanted.inspect}" unless actual == wanted
  end

  # The fields of the record, its resource, and its scope.
  def check_record(problems, message, record, entry)
    time     = Time.iso8601(entry["timestamp"])
    resource = record["resource"]
    # To the microsecond that :json writes, since :otlp_json_lines writes the nanosecond.
    received = record["timeUnixNano"].to_i / 1000
    expect(problems, message, "timeUnixNano (µs)", received, (time.to_r * 1_000_000).to_i)
    expect(problems, message, "severityNumber", record["severityNumber"], SEVERITY.fetch(entry["level"]))
    expect(problems, message, "scope", record["scope"], "Orders")
    expect(problems, message, "service.name", resource["service.name"], "checkout")
    expect(problems, message, "deployment.environment.name", resource["deployment.environment.name"], "test")
    expect(problems, message, "host.name", resource["host.name"], entry["host"])
    pid = resource["process.pid"]
    expect(problems, message, "process.pid", [pid, pid.class], [entry["pid"], Integer])
    expect(problems, message, "traceId", record["traceId"].to_s, entry["trace_id"].to_s)
    expect(problems, message, "spanId", record["spanId"].to_s, entry["span_id"].to_s)
    expect(problems, message, "flags", record["flags"].to_i, entry["trace_flags"].to_s.to_i(16))
  end

  # The fields of the :json entry that the operators leave as attributes, and none that they move.
  def check_json_attributes(problems, message, attrs, entry)
    %w[timestamp level level_index name message trace_id span_id trace_flags pid thread].each do |moved|
      problems << "#{message}: attribute #{moved} left in" if attrs.key?(moved)
    end
    expect(problems, message, "payload", attrs["payload"], entry["payload"]) if entry["payload"]
    expect(problems, message, "named_tags", attrs["named_tags"], entry["named_tags"]) if entry["named_tags"]
    return unless entry["exception"]

    expect(problems, message, "exception.name", attrs.dig("exception", "name"),
           entry.dig("exception", "name"))
  end

  # The attributes that Formatters::Otlp writes, flattened.
  def check_otlp_attributes(problems, message, attrs, entry)
    wanted = {}
    wanted["customer.tier"]  = "gold" if entry["payload"]
    wanted["user"]           = "jack" if entry["named_tags"]
    wanted["exception.type"] = entry.dig("exception", "name") if entry["exception"]
    wanted.each do |name, value|
      unless attrs[name] == value
        problems << "#{message}: attribute #{name} is #{attrs[name].inspect}, not #{value.inspect}"
      end
    end
  end
end

module FilelogTest
  DIR = __dir__

  # Where the log file and each agent's configuration are written: under the repository, since Docker
  # on macOS (Docker Desktop, Colima) shares only the home directory with its VM, not the system's tmp.
  WORK = File.expand_path("../../tmp/filelog", __dir__)

  COLLECTOR = "otel/opentelemetry-collector-contrib:0.166.0".freeze

  # Each agent: its image, where its configuration goes, how it starts, and its environment.
  AGENTS = {
    "collector"      => {
      image:  COLLECTOR,
      config: "/etc/otel/config.yaml",
      args:   ["--config", "/etc/otel/config.yaml"]
    },
    # The :otlp_json_lines file, which only the contrib build has a receiver for.
    "collector-otlp" => {
      image:    COLLECTOR,
      config:   "/etc/otel/config.yaml",
      args:     ["--config", "/etc/otel/config.yaml"],
      file:     "otlp_json_file.yaml",
      receiver: "otlpjsonfile/semantic_logger",
      otlp:     true
    },
    "edot"           => {
      image:  "docker.elastic.co/elastic-agent/elastic-otel-collector:9.5.7",
      config: "/etc/otel/config.yaml",
      args:   ["--config", "/etc/otel/config.yaml"]
    },
    "ddot"           => {
      image:  "datadog/agent:7.86.0-full",
      config: "/etc/datadog-agent/otel-config.yaml",
      args:   [],
      # DDOT starts inside the Datadog Agent, which needs an API key, even one that Datadog refuses.
      env:    {
        "DD_API_KEY"               => "abcdef0123456789" * 2,
        "DD_SITE"                  => "datadoghq.com",
        "DD_HOSTNAME"              => "filelog-test",
        "DD_OTELCOLLECTOR_ENABLED" => "true"
      },
      # Its own configuration, which the filelog pipeline is added to.
      base:   "/etc/datadog-agent/otel-config.yaml"
    },
    "alloy"          => {
      image:  "grafana/alloy:v1.22.0",
      config: "/etc/alloy/config.alloy",
      args:   ["run", "/etc/alloy/config.alloy", "--stability.level=public-preview", "--storage.path=/tmp/alloy"],
      alloy:  true
    }
  }.freeze

  NETWORK = "semantic-logger-filelog".freeze
  SINK    = "semantic-logger-filelog-sink".freeze
  AGENT   = "semantic-logger-filelog-agent".freeze

  TRACE_ID   = "5b8efff798038103d269b633813fc60c".freeze
  SPAN_ID    = "eee19b7ec3c1b174".freeze
  TAG_TRACE  = "0af7651916cd43dd8448eb211c80319c".freeze
  TAG_SPAN   = "b7ad6b7169203331".freeze
  # The entries that Semantic Logger writes to each file.
  EXPECTED   = 6
  # A line that another process wrote to the :json file, which the filelog agents read too.
  NOT_JSON   = "Segmentation fault (core dumped)".freeze
  # A JSON line without a level, which another process wrote, which keeps its text too.
  OTHER_JSON = '{"msg":"started","pid":1}'.freeze
  # The lines that another process wrote to the :json file.
  OTHER_LINES = [NOT_JSON, OTHER_JSON].freeze
  WAIT = 120

  module_function

  # Returns [String] what the docker command wrote, standard error included unless only `stdout:` is
  # wanted, such as a file that a container prints.
  def docker(*args, allow_failure: false, stdout: false)
    output, status = stdout ? Open3.capture2("docker", *args) : Open3.capture2e("docker", *args)
    raise("docker #{args.first(2).join(' ')} failed:\n#{output}") unless status.success? || allow_failure

    output
  end

  # Writes the log file with the :json formatter, and the same entries to the file with the
  # :otlp_json_lines formatter, returning each :json entry by its message.
  def write_log(file_name, otlp_file_name)
    # Without the resource of the developer's own environment, which :otlp_json_lines would write.
    ENV.delete("OTEL_SERVICE_NAME")
    ENV.delete("OTEL_RESOURCE_ATTRIBUTES")
    SemanticLogger.sync!
    SemanticLogger.default_level = :trace
    SemanticLogger.application   = "checkout"
    SemanticLogger.environment   = "test"
    appender = SemanticLogger.add_appender(file_name: file_name, formatter: :json)
    otlp     = SemanticLogger.add_appender(file_name: otlp_file_name, formatter: :otlp_json_lines)
    logger   = SemanticLogger["Orders"]

    context = OpenTelemetry::Trace::SpanContext.new(
      trace_id:    [TRACE_ID].pack("H*"),
      span_id:     [SPAN_ID].pack("H*"),
      trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED
    )
    OpenTelemetry::Trace.with_span(OpenTelemetry::Trace.non_recording_span(context)) do
      logger.info("Created order", order_id: 7, customer: {tier: "gold"})
    end
    SemanticLogger.named_tagged(trace_id: TAG_TRACE, span_id: TAG_SPAN, user: "jack") do
      logger.warn("Payment declined")
    end
    logger.error("Charge failed", RuntimeError.new("card expired"))
    SemanticLogger.tagged("cart") { logger.debug("Cart loaded") }
    # No message: the exception is the body, rather than the line as it was read.
    logger.error(ArgumentError.new("no message"))
    # An empty message stays the empty body, on both paths.
    logger.error("", ArgumentError.new("empty message"))
    SemanticLogger.flush
    SemanticLogger.remove_appender(appender)
    SemanticLogger.remove_appender(otlp)
    File.readlines(file_name).to_h do |line|
      entry = JSON.parse(line)
      [entry["message"], entry]
    end
  end

  # The configuration that the agent runs with: the published one, with a pipeline that sends to the sink.
  def agent_config(agent)
    if agent[:alloy]
      File.read(File.join(DIR, "filelog.alloy"))
    else
      config = YAML.safe_load_file(File.join(DIR, agent.fetch(:file, "filelog.yaml")))
      if agent[:base]
        base   = docker("run", "--rm", "--entrypoint", "cat", agent[:image], agent[:base], stdout: true)
        config = deep_merge(YAML.safe_load(base), config)
      end
      deep_merge(config, test_pipeline(agent.fetch(:receiver, "filelog/semantic_logger"))).to_yaml
    end
  end

  def test_pipeline(receiver)
    {
      "exporters" => {"otlphttp/sink" => {"endpoint" => "http://#{SINK}:4318"}},
      "service"   => {
        "extensions" => ["file_storage/semantic_logger"],
        "pipelines"  => {
          "logs/semantic_logger" => {"receivers" => [receiver], "exporters" => ["otlphttp/sink"]}
        }
      }
    }
  end

  def deep_merge(base, extra)
    base.merge(extra) do |_key, old, new|
      if old.is_a?(Hash) && new.is_a?(Hash) then deep_merge(old, new)
      elsif old.is_a?(Array) && new.is_a?(Array) then old | new
      else
        new
      end
    end
  end

  SINK_CONFIG = {
    "receivers" => {"otlp" => {"protocols" => {"http" => {"endpoint" => "0.0.0.0:4318"}}}},
    "exporters" => {"file" => {"path" => "/out/received.json"}},
    "service"   => {"pipelines" => {"logs" => {"receivers" => ["otlp"], "exporters" => ["file"]}}}
  }.freeze

  # Pulls the image, unless it is there already, so that a run needs no network once each was pulled.
  def pull(image)
    docker("image", "inspect", image) && return
  rescue RuntimeError
    docker("pull", "-q", image)
  end

  def run(name, agent, entries, logs)
    pull(agent[:image])
    Dir.mktmpdir("agent-#{name}-", WORK) do |work|
      out = writable_dir(work, "out")
      start_sink(work, out)
      start_agent(work, agent, logs)
      expected = agent[:otlp] ? EXPECTED : EXPECTED + OTHER_LINES.size
      records  = wait_for_records(out, expected)
      problems = Records.check(records, entries, otlp: agent[:otlp])
      problems << "received #{records.size} records, not #{expected}" unless records.size == expected
      unless problems.empty?
        puts docker("logs", "--tail", ENV.fetch("FILELOG_LOG_LINES", "40"), AGENT,
                    allow_failure: true)
      end
      problems
    ensure
      docker("rm", "-f", AGENT, SINK, allow_failure: true)
    end
  end

  # Returns [String] a directory that the user of any container can write to.
  def writable_dir(work, name)
    dir = File.join(work, name)
    FileUtils.mkdir_p(dir)
    FileUtils.chmod(0o777, dir)
    dir
  end

  # Starts the Collector that writes what the agent sends it to `out`/received.json.
  def start_sink(work, out)
    File.write(File.join(work, "sink.yaml"), SINK_CONFIG.to_yaml)
    docker("run", "-d", "--name", SINK, "--network", NETWORK,
           "-v", "#{work}/sink.yaml:/etc/sink.yaml:ro", "-v", "#{out}:/out",
           COLLECTOR, "--config", "/etc/sink.yaml")
  end

  # Starts the agent with its configuration, reading the log files, and keeping its offsets in a
  # directory of its own.
  def start_agent(work, agent, logs)
    File.write(File.join(work, "agent"), agent_config(agent))
    storage = writable_dir(work, "storage")
    env     = {"FILELOG_STORAGE_DIR" => "/var/lib/filelog", "OTLP_ENDPOINT" => "http://#{SINK}:4318"}
    env.merge!(agent[:env]) if agent[:env]
    docker("run", "-d", "--name", AGENT, "--network", NETWORK,
           *env.flat_map { |key, value| ["-e", "#{key}=#{value}"] },
           "-v", "#{work}/agent:#{agent[:config]}:ro",
           "-v", "#{logs}:/var/log/app:ro",
           "-v", "#{storage}:/var/lib/filelog",
           agent[:image], *agent[:args])
  end

  # Returns [Array<Hash>] the records received, once there are as many as expected, or WAIT seconds passed.
  def wait_for_records(out, expected)
    deadline = Time.now + WAIT
    records  = []
    until Time.now > deadline
      records = Records.received(out)
      break if records.size >= expected

      sleep 2
    end
    records
  end

  def main(names)
    names = AGENTS.keys if names.empty?
    unknown = names - AGENTS.keys
    abort("Unknown agent(s): #{unknown.join(', ')}. Choose from: #{AGENTS.keys.join(', ')}") unless unknown.empty?

    FileUtils.mkdir_p(WORK)
    Dir.mktmpdir("logs-", WORK) do |logs|
      FileUtils.chmod(0o755, logs)
      log_file = File.join(logs, "app.log")
      entries  = write_log(log_file, File.join(logs, "app.jsonl"))
      File.write(log_file, OTHER_LINES.map { |line| "#{line}\n" }.join, mode: "a")
      Dir[File.join(logs, "*")].each { |file| FileUtils.chmod(0o644, file) }
      pull(COLLECTOR)
      docker("network", "create", NETWORK, allow_failure: true)
      results = names.to_h do |name|
        puts "== #{name} (#{AGENTS[name][:image]})"
        problems = run(name, AGENTS[name], entries, logs)
        puts problems.empty? ? "PASS" : problems.map { |problem| "FAIL #{problem}" }
        [name, problems.empty?]
      end
      puts
      results.each { |name, passed| puts "#{passed ? 'PASS' : 'FAIL'}  #{name}" }
      exit(results.values.all? ? 0 : 1)
    ensure
      docker("network", "rm", NETWORK, allow_failure: true)
    end
  end
end

FilelogTest.main(ARGV) if $PROGRAM_NAME == __FILE__
