require "openssl"
require "uri"

module SemanticLogger
  module Metric
    class Otlp < SemanticLogger::Appender::Http
      # The OpenTelemetry environment variables that configure an OTLP metric exporter: reads them,
      # parses their values as the OpenTelemetry specification describes, and reports, on the logger it
      # is given, a value that it cannot use and so ignores. Otlp decides what each one applies to, and
      # which of its own options win over them.
      #
      # A variable of the metrics signal, such as OTEL_EXPORTER_OTLP_METRICS_HEADERS, replaces its
      # generic one, such as OTEL_EXPORTER_OTLP_HEADERS, as a whole. A variable that is empty, or holds
      # only blanks, counts as not set, as does one that is not valid UTF-8, which is reported by its
      # name only. Each value is parsed, and any problem with it reported, once, when it is first asked
      # for.
      #
      # See https://opentelemetry.io/docs/specs/otel/protocol/exporter/ and
      # https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
      class Environment
        # A header name: an HTTP token (RFC 9110).
        HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

        # Characters that a header value cannot hold: anything other than a tab and the printable ASCII
        # characters. RFC 9110 lets a value hold bytes above 0x7F too, but gives them no meaning, and
        # Net::HTTP would send the UTF-8 of a decoded value as it is.
        HEADER_VALUE_INVALID = /[^\t\x20-\x7E]/

        # The compression of each value of OTEL_EXPORTER_OTLP_COMPRESSION that it knows: true for gzip.
        COMPRESSIONS = {"gzip" => true, "none" => false}.freeze

        # Milliseconds in a second, to convert the timeout.
        MILLISECONDS = 1000.0

        # The variable of the seconds between exports, in milliseconds (see #export_interval).
        EXPORT_INTERVAL = "OTEL_METRIC_EXPORT_INTERVAL".freeze

        # The timeout when it is not set, or ignored (see #timeout?).
        UNSET = Object.new.freeze
        private_constant :UNSET

        # Parameters:
        #   logger: [SemanticLogger::Logger]
        #     Reports a value that cannot be used, never with a header value, which may hold credentials.
        def initialize(logger)
          @logger = logger
        end

        # Returns [String|nil] the full url to post the metrics to.
        def endpoint
          value("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
        end

        # Returns [String|nil] the base url of the OTLP/HTTP receiver.
        def base_url
          value("OTEL_EXPORTER_OTLP_ENDPOINT")
        end

        # Returns [String|nil] the name of the service.
        def service_name
          value("OTEL_SERVICE_NAME")
        end

        # Returns [Hash<String, String>] the headers to send with each request, none when not set. An
        # entry that is not a valid `name=value`, once percent-decoded, is left out and reported.
        def headers
          return @headers if defined?(@headers)

          name, text = signal_value("HEADERS")
          @headers   = text ? parse_headers(name, text).freeze : {}.freeze
        end

        # Returns [true|false] whether the timeout is set, to a value that can be used (see #timeout).
        def timeout?
          !timeout_seconds.equal?(UNSET)
        end

        # Returns [Float|nil] the timeout, in seconds; nil when it is 0, meaning no limit, or when it is
        # not set (see #timeout?). It is given in whole milliseconds; a value that is not is ignored and
        # reported.
        def timeout
          seconds = timeout_seconds
          seconds unless seconds.equal?(UNSET)
        end

        # Returns [true|false|nil] whether to compress the requests with gzip, nil when not set. A value
        # other than "gzip" or "none", in any case, is ignored and reported.
        def compress
          return @compress if defined?(@compress)

          name, text = signal_value("COMPRESSION")
          @compress  = text && parse_compression(name, text)
        end

        # Returns [Hash] the TLS options of Appender::Http (`ssl:`) that the certificate variables set,
        # none when none is set: `ca_file:`, the file of trusted certificates to verify the server with,
        # from CERTIFICATE, and `cert:` and `key:`, the client's certificate and private key, read from
        # the PEM files of CLIENT_CERTIFICATE and CLIENT_KEY. Each file is read when first asked for.
        #
        # Raises ArgumentError, naming the variable and its file, for a file that cannot be read, or
        # that does not hold a PEM certificate or private key: every request would fail without it.
        def ssl
          return @ssl if defined?(@ssl)

          ssl = {}
          name, path = signal_value("CERTIFICATE")
          ssl[:ca_file] = readable_file(name, path) if path
          name, path = signal_value("CLIENT_CERTIFICATE")
          ssl[:cert] = read_pem(name, path, "certificate") { |pem| OpenSSL::X509::Certificate.new(pem) } if path
          name, path = signal_value("CLIENT_KEY")
          ssl[:key] = read_pem(name, path, "private key") { |pem| OpenSSL::PKey.read(pem) } if path
          @ssl = ssl.freeze
        end

        # Returns [Float|nil] the seconds between exports of OTEL_METRIC_EXPORT_INTERVAL, given in
        # milliseconds, nil when not set. A value that is not a positive whole number of milliseconds is
        # ignored and reported.
        def export_interval
          return @export_interval if defined?(@export_interval)

          text             = value(EXPORT_INTERVAL)
          @export_interval = text && parse_export_interval(text)
        end

        # Returns [Hash<String, String>] the attributes of the resource, none when not set. When any entry
        # is not a valid `key=value`, once percent-decoded, the whole value is ignored and reported, as the
        # OpenTelemetry specification of the resource SDK asks.
        def resource_attributes
          return @resource_attributes if defined?(@resource_attributes)

          text                 = value("OTEL_RESOURCE_ATTRIBUTES")
          @resource_attributes = ((text && parse_resource_attributes(text)) || {}).freeze
        end

        private

        attr_reader :logger

        # Returns [Float|nil|UNSET] the timeout in seconds, nil for no limit, UNSET when not set or ignored.
        def timeout_seconds
          return @timeout_seconds if defined?(@timeout_seconds)

          name, text       = signal_value("TIMEOUT")
          @timeout_seconds = text ? parse_timeout(name, text) : UNSET
        end

        def parse_timeout(name, text)
          text = text.strip
          unless text.match?(/\A\d+\z/)
            logger.warn("Ignoring #{name}=#{text.inspect}: not a whole number of milliseconds")
            return UNSET
          end

          milliseconds = Integer(text, 10)
          milliseconds.zero? ? nil : milliseconds / MILLISECONDS
        end

        def parse_export_interval(text)
          text = text.strip
          if text.match?(/\A\d+\z/) && Integer(text, 10).positive?
            Integer(text, 10) / MILLISECONDS
          else
            logger.warn("Ignoring #{EXPORT_INTERVAL}=#{text.inspect}: not a positive whole number of milliseconds")
            nil
          end
        end

        # Returns [String] the path of the file, raising ArgumentError, naming the variable, when it is
        # not a file that can be read.
        def readable_file(name, path)
          return path if File.file?(path) && File.readable?(path)

          raise(ArgumentError, "#{name}: cannot read the file #{path.inspect}")
        end

        # Returns what the block makes of the text of the PEM file, raising ArgumentError, naming the
        # variable, the file, and what it should hold, when it cannot be read, or the block cannot parse it.
        def read_pem(name, path, what)
          yield(File.read(readable_file(name, path)))
        rescue OpenSSL::OpenSSLError, SystemCallError, IOError => e
          raise(ArgumentError, "#{name}: the file #{path.inspect} does not hold a PEM #{what}: #{e.message}")
        end

        def parse_compression(name, text)
          compress = COMPRESSIONS[text.strip.downcase]
          return compress unless compress.nil?

          logger.warn("Ignoring #{name}=#{text.strip.inspect}: the compression is neither gzip nor none")
          nil
        end

        # The entries that are not valid are reported by their position only, since their text may be or
        # hold a credential.
        def parse_headers(name, text)
          headers = {}
          invalid = []
          each_entry(text) do |key, value, position|
            if key&.match?(HEADER_NAME) && !value.match?(HEADER_VALUE_INVALID)
              headers[key] = value
            else
              invalid << position
            end
          end
          unless invalid.empty?
            logger.warn("Ignoring the entries of #{name} at position(s) #{invalid.join(', ')}: not a valid name=value")
          end
          headers
        end

        def parse_resource_attributes(text)
          attributes = {}
          invalid    = []
          each_entry(text) do |key, value, position|
            if key.nil? || key.empty?
              invalid << position
            else
              attributes[key] = value
            end
          end
          return attributes if invalid.empty?

          logger.warn(
            "Ignoring OTEL_RESOURCE_ATTRIBUTES: the entries at position(s) #{invalid.join(', ')} " \
            "are not a valid key=value"
          )
          nil
        end

        # Yields the key and value of each comma-separated `key=value` entry of the text, trimmed and
        # percent-decoded, and its position, counted from 1, skipping blank entries. The key is nil when
        # the entry has no "=", or does not percent-decode to valid UTF-8; the value is then "".
        def each_entry(text)
          text.split(",").each_with_index do |entry, index|
            next if entry.strip.empty?

            key, separator, value = entry.partition("=")
            key   = decode(key.strip)
            value = decode(value.strip)
            key   = nil if separator.empty? || value.nil?
            yield key, value || "", index + 1
          end
        end

        # Returns [String|nil] the text percent-decoded, nil when it is not valid percent-encoded UTF-8.
        def decode(text)
          decoded = URI.decode_uri_component(text)
          decoded if decoded.valid_encoding?
        rescue ArgumentError
          nil
        end

        # Returns [Array<String>] the name and value of the metrics variable of the setting, or else of
        # its generic one; a nil value when neither is set.
        def signal_value(setting)
          name = "OTEL_EXPORTER_OTLP_METRICS_#{setting}"
          text = value(name)
          return [name, text] if text

          name = "OTEL_EXPORTER_OTLP_#{setting}"
          [name, value(name)]
        end

        # Returns [String|nil] the value of the environment variable, as UTF-8, nil when it is not set,
        # blank, or not valid UTF-8. A value that is not valid UTF-8 is reported once, by the name of the
        # variable only, since its value may hold a credential.
        def value(name)
          text = ENV.fetch(name, nil)
          return if text.nil?

          text = text.dup.force_encoding(Encoding::UTF_8)
          unless text.valid_encoding?
            report_invalid_encoding(name)
            return
          end

          text unless text.strip.empty?
        end

        def report_invalid_encoding(name)
          @invalid_encodings ||= []
          return if @invalid_encodings.include?(name)

          @invalid_encodings << name
          logger.warn("Ignoring #{name}: its value is not valid UTF-8")
        end
      end
    end
  end
end
