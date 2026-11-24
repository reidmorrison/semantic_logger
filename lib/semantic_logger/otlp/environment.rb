require "openssl"
require "uri"

module SemanticLogger
  module Otlp
    # The OpenTelemetry environment variables that configure an OTLP exporter of one signal, metrics
    # or logs (see Signal): reads them, parses their values as the OpenTelemetry specification
    # describes, and reports, on the logger it is given, a value that it cannot use and so ignores.
    # The appender (see Exporter) decides what each one applies to, and which of its own options win
    # over them.
    #
    # A variable of the signal, such as OTEL_EXPORTER_OTLP_METRICS_HEADERS or
    # OTEL_EXPORTER_OTLP_LOGS_HEADERS, replaces its generic one, such as OTEL_EXPORTER_OTLP_HEADERS, as
    # a whole. A variable that is empty, or holds only blanks, counts as not set, as does one that is
    # not valid UTF-8, which is reported by its name only. Each value is parsed, and any problem with
    # it reported, once, when it is first asked for.
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
      #
      #   signal: [Otlp::Signal]
      #     The signal whose variables it reads besides the generic ones.
      def initialize(logger, signal)
        @logger = logger
        @signal = signal
      end

      # Returns [String|nil] the full url to post the requests of the signal to.
      def endpoint
        value("OTEL_EXPORTER_OTLP_#{signal.variable}_ENDPOINT")
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

      # Returns [String|nil] the name of the OTLP/HTTP protocol to send with, such as "http/protobuf",
      # nil when not set. "grpc", which the appender cannot send, is reported, and taken as
      # "http/protobuf", the encoding of gRPC; any other value that Protocol does
      # not know is ignored and reported.
      def protocol
        return @protocol if defined?(@protocol)

        name, text = signal_value("PROTOCOL")
        @protocol  = text && parse_protocol(name, text.strip)
      end

      # The certificate variables below each name a file, which is read only when asked for, so that a
      # variable whose option the appender was given, and so does not ask for, is never read. Each
      # raises ArgumentError, naming the variable and its file, for a file that cannot be read, or
      # that does not hold what it should: every request would fail without it.

      # Returns [String|nil] the path of CERTIFICATE, the PEM file of trusted certificates to verify
      # the server with, nil when not set.
      def ca_file
        return @ca_file if defined?(@ca_file)

        name, path = signal_value("CERTIFICATE")
        @ca_file   = path && read_pem(name, path, "certificate") do
          OpenSSL::X509::Store.new.add_file(path)
          path
        end
      end

      # Returns [Hash] the client's certificate and private key, as the `cert:` and `key:` of `ssl:`, from
      # the PEM files of CLIENT_CERTIFICATE and CLIENT_KEY; none when neither is set. Raises ArgumentError
      # when only one of them is set, or the key is not the private key of the certificate, such as when
      # one is of the signal and the other generic, since every request would then fail. An encrypted
      # key raises, rather than asking for its pass phrase on a terminal: the specification has no
      # variable for one.
      def client_identity
        return @client_identity if defined?(@client_identity)

        cert_name, cert_path = signal_value("CLIENT_CERTIFICATE")
        key_name, key_path   = signal_value("CLIENT_KEY")
        return @client_identity = {}.freeze if cert_path.nil? && key_path.nil?

        missing = cert_path.nil? ? "CLIENT_CERTIFICATE" : "CLIENT_KEY" unless cert_path && key_path
        if missing
          raise(ArgumentError,
                "#{cert_path ? cert_name : key_name} is set without " \
                "OTEL_EXPORTER_OTLP_#{signal.variable}_#{missing} or " \
                "OTEL_EXPORTER_OTLP_#{missing}: a client certificate needs both")
        end

        cert = read_pem(cert_name, cert_path, "certificate") { OpenSSL::X509::Certificate.new(File.read(cert_path)) }
        key  = read_pem(key_name, key_path, "private key, without a pass phrase") do
          key = OpenSSL::PKey.read(File.read(key_path), "")
          raise(OpenSSL::PKey::PKeyError, "it holds a public key") unless private_key?(key)

          key
        end
        unless cert.check_private_key(key)
          raise(ArgumentError, "#{key_name} does not hold the private key of the certificate of #{cert_name}")
        end

        @client_identity = {cert: cert, key: key}.freeze
      end

      # Returns [Float|nil] the seconds between exports of OTEL_METRIC_EXPORT_INTERVAL, given in
      # milliseconds, nil when not set: a variable of the metrics SDK, whatever the signal. A value
      # that is not a positive whole number of milliseconds is ignored and reported.
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

      attr_reader :logger, :signal

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

      def parse_protocol(name, text)
        text = text.downcase
        return text if Protocol.known?(text)

        if text == "grpc"
          logger.warn(
            "#{name}=grpc: the :otlp #{signal.kind} appender sends OTLP/HTTP only, so it sends http/protobuf, " \
            "which needs the url of an OTLP/HTTP receiver, such as port 4318 rather than 4317 of gRPC"
          )
          return Protocol::DEFAULT
        end

        logger.warn("Ignoring #{name}=#{text.inspect}: the protocol is neither http/protobuf nor http/json")
        nil
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

      # Returns [true|false] whether the key holds its private part. A key of a type without #private?, such as
      # Ed25519, is asked for its private part instead.
      def private_key?(key)
        return key.private? if key.respond_to?(:private?)

        key.private_to_der
        true
      rescue OpenSSL::PKey::PKeyError
        false
      end

      # Returns what the block makes of the PEM file, raising ArgumentError, naming the variable and the
      # file, when it is not a file that can be read, or, saying what it should hold, when the block
      # cannot parse it.
      def read_pem(name, path, what)
        unless File.file?(path) && File.readable?(path)
          raise(ArgumentError,
                "#{name}: cannot read the file #{path.inspect}")
        end

        yield
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

      # Returns [Array<String>] the name and value of the variable of the setting for the signal, or
      # else of its generic one; a nil value when neither is set.
      def signal_value(setting)
        name = "OTEL_EXPORTER_OTLP_#{signal.variable}_#{setting}"
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
