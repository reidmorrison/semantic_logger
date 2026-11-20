require "net/http"
require "uri"
require "socket"
require "json"
require "openssl"

# Log to any HTTP(S) server that accepts log messages in JSON form
#
# Features:
# * JSON Formatted messages.
# * Uses a persistent http connection, if the server supports it.
# * SSL encryption (https).
#
# Example:
#   SemanticLogger.add_appender(
#     appender: :http,
#     url:      'http://localhost:8088/path'
#   )
#
# Batching:
# By default each log message is posted individually. To post multiple log
# messages in a single request as a JSON array (for example to the Filebeat
# http_endpoint input), enable batching when adding the appender:
#   SemanticLogger.add_appender(
#     appender: :http,
#     url:      'http://localhost:8088/path',
#     batch:    true
#   )
#
# Responses:
# A response other than 2xx raises ResponseError from #log and #batch. A 4xx other than 408 and
# 429 rejects the request itself, so #message_error? recognizes it, and an asynchronous appender
# discards the entries straight away, counted as failed. A batch rejected for what it holds (400,
# 413, or 422) is first split up and each part sent again, to find the entries at fault; any other
# such 4xx, such as 401 or 404, would reject any part too, so the whole batch is discarded at once
# (see #fails_any_batch?). Any other status is a problem with the destination, so an asynchronous
# appender backs off. After a 408, 429, or 503, which ask to send the request again later, it then
# sends the entries again, up to QueueProcessor::HeldWrite::MAX_RESENDS times, since the server did
# not store them (see #wrote_nothing?). After any other, such as a 500, 502, 504, or a redirect, it
# discards them, counted as failed. An appender that is not asynchronous reports the error.
module SemanticLogger
  module Appender
    class Http < SemanticLogger::Subscriber
      attr_accessor :username, :compress, :header,
                    :open_timeout, :read_timeout, :continue_timeout
      attr_reader :http, :url, :server, :port, :path, :query, :ssl_options, :proxy_url

      # Maximum number of bytes of an error response body to write to the internal logger.
      MAX_LOGGED_RESPONSE_BODY = 512

      # Raised when the server answers a request with a status other than 2xx. Its message holds
      # the status code, the redacted url, and the start of the response body, for the internal
      # logger.
      class ResponseError < StandardError
        # The statuses that ask the client to send the request again later, after which the server
        # has not stored it: 408 Request Timeout, 429 Too Many Requests, and 503 Service
        # Unavailable. Not a 500, which often comes again for the same request, or a 502 Bad Gateway
        # or 504 Gateway Timeout, which a proxy can answer once the server behind it has stored it.
        RETRY_LATER_CODES = [408, 429, 503].freeze

        # The 4xx statuses that reject the request for the entries it holds: 400 Bad Request,
        # 413 Content Too Large, and 422 Unprocessable Content. A server can answer 400 for its own
        # configuration too, such as Splunk's HTTP Event Collector for an index it does not know, which
        # then rejects every part of a batch split up to find the entries at fault. A subclass that
        # can tell such an answer from its body says so from #fails_any_batch?, as
        # Appender::SplunkHttp does.
        CONTENT_CODES = [400, 413, 422].freeze

        # Returns [Integer] the status code of the response.
        attr_reader :code

        # Returns [String|nil] the body of the response, for a subclass that reads the server's own
        # reason from it, such as Appender::SplunkHttp. Not in the message beyond its start, see
        # MAX_LOGGED_RESPONSE_BODY.
        attr_reader :body

        def initialize(message, code:, body: nil)
          super(message)
          @code = code
          @body = body
        end

        # Whether the server rejected the request itself, with a 4xx status other than 408 and
        # 429, so that sending it again cannot succeed. A 408, 429, or 5xx, and a 3xx, which asks to
        # send it elsewhere, are problems with the destination instead.
        def rejected?
          (400..499).cover?(code) && !retry_later?
        end

        # Whether the server asks to send the request again later (see RETRY_LATER_CODES).
        def retry_later? = RETRY_LATER_CODES.include?(code)

        # Whether the server rejected the request for the entries it holds (see CONTENT_CODES), so
        # that it may accept a part of them. It rejects a request with any other 4xx (see
        # #rejected?), such as 401 Unauthorized, 403 Forbidden, or 404 Not Found, whatever it holds.
        def content_rejected?
          CONTENT_CODES.include?(code)
        end
      end

      # Describes a valid url in the error raised for an invalid one.
      URL_FORMAT_HINT = "Should be similar to: 'http://hostname:port/path'".freeze

      # The errors raised when the appender cannot connect to the server, so that the request was
      # never sent: the server's name does not resolve, it cannot be reached, or it does not accept
      # the connection, refusing it or within the open_timeout. Once connected, an error such as a
      # read timeout or a reset connection may come after the server took the request.
      NOT_SENT_ERRORS = [
        SocketError, Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
        Errno::EADDRNOTAVAIL
      ].freeze

      # Create HTTP(S) log appender
      #
      # Parameters:
      #   url: [String]
      #     Valid URL to post to.
      #       Example: http://example.com/some_path
      #     To enable SSL include https in the URL.
      #       Example: https://example.com/some_path
      #       verify_mode will default: OpenSSL::SSL::VERIFY_PEER
      #     A query string is kept and sent with every request that submits log data,
      #     for the log servers that are configured through it.
      #       Example: http://example.com/some_path?source=my_app
      #
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   username: [String]
      #     User name for basic Authentication.
      #     Default: nil ( do not use basic auth )
      #
      #   password: [String]
      #     Password for basic Authentication.
      #
      #   header: [Hash]
      #     Custom HTTP headers to send with each request. Each one replaces the default header of the
      #     same name, compared in any case, such as "content-type" for Content-Type. A header set later
      #     through #header, or written to it directly by a subclass, is not compared in any case.
      #     Default: {} ( do not send any custom headers)
      #     Example: {"Authorization" => "Bearer BEARER_TOKEN"}
      #
      #   compress: [true|false]
      #     Whether to compress the JSON string with GZip.
      #     Default: false
      #
      #   ssl: [Hash]
      #     Specific SSL options: For more details see NET::HTTP.start
      #       ca_file, ca_path, cert, cert_store, ciphers, key, ssl_timeout,
      #       ssl_version, verify_callback, verify_depth and verify_mode.
      #
      #   proxy_url: [String]
      #     URL of proxy server to use for HTTP(s) connections.  Should
      #       include username and password if required.
      #       Example: http://user@pass:example.com/some_path
      #     To enable SSL include https in the URL.
      #       Example: https://example.com/some_path
      #     If this is set to :ENV, Net::HTTP will use the environment http_proxy*
      #       variables if they are set.  If set to nil then no proxy will be used,
      #       even if the environment variables are set.
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: none (:trace), so it writes every entry that a logger emits; each logger
      #     filters by its own level.
      #
      #   formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: SemanticLogger::Formatters::Json
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   open_timeout: [Float]
      #     Default: 2.0
      #
      #   read_timeout: [Float]
      #     Default: 1.0
      #
      #   continue_timeout: [Float]
      #     Default: 1.0
      def initialize(url:,
                     compress: false,
                     ssl: {},
                     username: nil,
                     password: nil,
                     header: {},
                     proxy_url: :ENV,
                     open_timeout: 2.0,
                     read_timeout: 1.0,
                     continue_timeout: 1.0,
                     **args,
                     &)
        @url              = url
        @proxy_url        = proxy_url
        # A copy, to which an https url adds use_ssl: and verify_mode: (see Subscriber#copy_options).
        @ssl_options      = ssl && copy_options(ssl)
        @username         = username
        @password         = password
        @compress         = compress
        @open_timeout     = open_timeout
        @read_timeout     = read_timeout
        @continue_timeout = continue_timeout

        # On Ruby v2.0 and greater, Net::HTTP.new already uses a persistent connection if the server allows it
        @header = {
          "Accept"       => "application/json",
          "Content-Type" => "application/json",
          "Connection"   => "keep-alive",
          "Keep-Alive"   => "300"
        }
        header&.each { |name, value| replace_header(name, value) }
        replace_header("Content-Encoding", "gzip") if @compress

        uri     = parse_url(@url)
        @server = uri.host
        # The url is left out of the message, since it can hold a user and password.
        raise(ArgumentError, "Invalid format for :url, it has no host. #{URL_FORMAT_HINT}") unless @server

        @port     = uri.port
        @username = uri.user if !@username && uri.user
        @password = uri.password if !@password && uri.password
        @path     = uri.path
        # Path cannot be empty
        @path     = "/" if @path == ""
        # Query string of the url, applied to every request, see #uri_with_query.
        # Kept separate from the path, because subclasses build their own request paths
        # from it. For example Appender::ElasticsearchHttp appends the index name.
        @query    = uri.query
        @query    = nil if @query == ""

        if uri.scheme == "https"
          @ssl_options[:use_ssl] = true
          @ssl_options[:verify_mode] ||= OpenSSL::SSL::VERIFY_PEER
          @port                      ||= HTTP.https_default_port
        else
          @port ||= HTTP.http_default_port
        end

        @proxy_uri = Utils.parse_url(@proxy_url, option: ":proxy_url") if @proxy_url && @proxy_url != :ENV

        @http = nil

        super(**args, &)
        reopen
      end

      # Closes the connection, if it is open, and starts a new one, such as after a log rotation, or a
      # fork. When starting it fails, such as while the server cannot be reached, it raises, and the
      # next request starts it (see #process_request).
      #
      # After a fork, the child first forgets the connection it inherited, without finishing it: it
      # belongs to the parent. Finishing an https connection sends the server a TLS close_notify, which
      # ends the connection for the parent too. Ruby closes the child's copy of the socket when it
      # collects it, which leaves the parent's open. Net::HTTP keeps its socket to itself, so until then
      # the child holds that copy open, and over plain http the server does not see the connection end
      # when the parent closes it.
      def reopen
        finish_connection
        build_http.start
      end

      # Closes the connection, if it is open, such as when the appender is removed, or add_appender
      # fails to add it. The next request opens it again, see #process_request.
      #
      # In a forked child that has not reopened, such as one that removes the appender before its
      # reopen has run, it forgets the connection it inherited instead, without finishing it, since it
      # belongs to the parent (see #reopen), and the next request starts a new one.
      def close
        finish_connection
      end

      # Forward log messages to HTTP Server
      def log(log)
        message = format_log(log)
        logger.trace(message)
        post(message)
      end

      # Forward a batch of log messages to the HTTP Server in a single request.
      # Only used when the appender is created with `batch: true`.
      def batch(logs)
        message = format_batch(logs)
        logger.trace(message)
        post(message)
      end

      # The HTTP appender supports batching, but only when explicitly requested
      # via `batch: true`, so that the default behaviour (one request per log
      # message) is preserved.
      def batch_by_default?
        false
      end

      # The whole batch is formatted into a single request before anything is sent, and the
      # server answers for the request as a whole. So a batch that a format error or a rejected
      # request fails (see #message_error?) is split up and sent again, to find the entries at
      # fault.
      def batch_all_or_nothing?
        true
      end

      # The #batch above formats the whole batch with #format_batch, so it needs a formatter that can
      # format a batch, such as the default one, rather than a formatter block. See
      # Subscriber#batch_refusal.
      #
      # Answers only while that #batch is the one in use (see Subscriber#batch_defined_by?). A
      # subclass that replaces it answers for its own, as Loki and Signalfx do, and is otherwise
      # batched with any formatter, as before, such as one whose #batch formats each log message with
      # #format_log. One whose #batch calls super, or that a prepended module wraps, still formats the
      # whole batch with #format_batch, so it defines its own #batch_refusal, which returns
      # #format_batch_refusal, as the Custom appenders section of docs/config.md shows.
      def batch_refusal
        format_batch_refusal if batch_defined_by?(Http)
      end

      # Whether the exception, raised by #log or #batch, was caused by the entries sent, rather
      # than by the destination (see Subscriber#message_error?). That includes a request the
      # server rejected (see ResponseError#rejected?), since sending it again cannot succeed.
      def message_error?(exception)
        (exception.is_a?(ResponseError) && exception.rejected?) || super
      end

      # Whether the exception, a message error, would fail any batch, whatever entries it holds (see
      # Subscriber#fails_any_batch?): the server rejected the request (see ResponseError#rejected?)
      # other than for the entries it holds (see ResponseError#content_rejected?), such as for its
      # credentials or its url, and would reject every part of the batch too. So the batch is
      # discarded at once, rather than split up. A batch that could not be formatted, or that the
      # server rejected for its entries, is split up to find the entries at fault.
      def fails_any_batch?(exception)
        exception.is_a?(ResponseError) && exception.rejected? && !exception.content_rejected?
      end

      # Whether the request that raised the exception from #log or #batch stored none of its
      # entries, and is worth sending again later (see Subscriber#wrote_nothing?): the server asked
      # to send it again later (see ResponseError#retry_later?), or it was never sent (see
      # #not_sent?). So an asynchronous appender sends the entries again once it has backed off.
      #
      # Decided from the class of the exception alone. Its cause, which Ruby sets to the error being
      # handled when it was raised, such as a format error while a batch is split, says nothing about
      # this request; #process_request raises the error of the request, not one from reconnecting.
      #
      # A subclass whose #log or #batch sends more than one request must override this to return
      # false: a failure of a later request would otherwise have the entries of the earlier ones,
      # which the server stored, sent again.
      def wrote_nothing?(exception)
        return exception.retry_later? if exception.is_a?(ResponseError)

        not_sent?(exception)
      end

      # Whether the request that raised the exception from #log or #batch was never sent, because
      # the appender could not connect (see NOT_SENT_ERRORS), so that the server has not answered it
      # (see Subscriber#not_sent?). An asynchronous appender then sends the entries again without
      # counting it towards QueueProcessor::HeldWrite::MAX_RESENDS, so that an outage loses none of
      # them until the worker thread gives up after async_max_retries. Decided from the class of the
      # exception alone, as for #wrote_nothing?.
      def not_sent?(exception)
        NOT_SENT_ERRORS.any? { |error_class| exception.is_a?(error_class) }
      end

      # Returns [String] the scheme, host, and any non-default port of the url. Safe to log.
      # See Utils.redacted_url.
      def redacted_url
        @redacted_url ||= Utils.redacted_url(url)
      end

      # Only the redacted url, since the instance variables hold the password, the authorization
      # headers, and any credential a subclass adds. See Subscriber#inspect.
      def inspect_details
        "url=#{redacted_url.inspect}"
      end

      private

      # Sets the header of that name, replacing one whose name differs from it only in case, since HTTP
      # header names are case-insensitive: otherwise both would be kept, and Net::HTTP would send only
      # one of them, reporting the other as duplicated under -W. The name is kept as given, a String or
      # a Symbol.
      def replace_header(name, value)
        @header.delete_if { |existing, _value| existing.to_s.casecmp?(name.to_s) }
        @header[name] = value
      end

      # Returns [Net::HTTP] a new connection, not yet started, after making it the appender's. Records
      # the process that built it, which owns its connection (see #reopen).
      def build_http
        @http = if @proxy_uri
                  Net::HTTP.new(server, port, @proxy_uri.host, @proxy_uri.port, @proxy_uri.user, @proxy_uri.password)
                else
                  Net::HTTP.new(server, port, @proxy_url)
                end

        if @ssl_options
          @http.methods.grep(/\A(\w+)=\z/) do |meth|
            key = Regexp.last_match(1).to_sym
            @ssl_options.key?(key) || next
            @http.__send__(meth, @ssl_options[key])
          end
        end

        @http.open_timeout     = @open_timeout
        @http.read_timeout     = @read_timeout
        @http.continue_timeout = @continue_timeout
        @pid                   = ::Process.pid
        @http
      end

      # Finishes the connection, if it is open. In a child process, first forgets the connection
      # started in the parent before a fork, without finishing it. See #reopen.
      #
      # Used by #reopen as well as #close, rather than #reopen calling #close, so that a subclass's
      # #close is not run by a reopen.
      def finish_connection
        forget_inherited
        @http&.finish
      rescue IOError
        nil
      end

      # In a child process, forgets the connection started in the parent before a fork. See #reopen.
      def forget_inherited
        @http = nil unless @pid == ::Process.pid
      end

      # Returns [URI] the parsed url, without the url in the error raised for an invalid one.
      def parse_url(url)
        Utils.parse_url(url, hint: URL_FORMAT_HINT)
      end

      # Use JSON Formatter by default
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end

      def compress_data(data)
        str = StringIO.new
        gz  = Zlib::GzipWriter.new(str)
        gz << data
        gz.close
        str.string
      end

      # HTTP Post
      def post(body, request_uri = path)
        request = Net::HTTP::Post.new(uri_with_query(request_uri), @header)
        process_request(request, body)
      end

      # HTTP Put
      def put(body, request_uri = path)
        request = Net::HTTP::Put.new(uri_with_query(request_uri), @header)
        process_request(request, body)
      end

      # HTTP Delete
      #
      # The query string of the configured url is _not_ applied here: it configures how
      # the server ingests log data, and servers reject it on a maintenance request.
      # Appender::ElasticsearchHttp#delete_all deletes an index, and Elasticsearch fails
      # the request with a 400 when it carries unrecognized parameters.
      #
      # A maintenance request is not log data written by the worker thread of an asynchronous
      # appender, so a response other than 2xx is reported to the internal logger, and false
      # returned, rather than raised.
      def delete(request_uri = path)
        request = Net::HTTP::Delete.new(request_uri, @header)
        process_request(request)
      rescue ResponseError => e
        logger.error(e.message)
        false
      end

      # Applies the query string of the configured url, if any, to the uri of a request
      # that submits log data.
      #
      # Kept out of `path` on purpose: subclasses build their own request paths from it
      # (Appender::ElasticsearchHttp appends the index name and `_doc` to it), and the
      # query has to stay at the end of the request uri regardless.
      #
      # @param request_uri [String] path of the request, `path` by default.
      # @return [String]
      def uri_with_query(request_uri)
        return request_uri unless @query

        separator = request_uri.include?("?") ? "&" : "?"
        "#{request_uri}#{separator}#{@query}"
      end

      # Process HTTP Request
      #
      # Returns true when the server answers with a 2xx status. Raises ResponseError for any other
      # status, so that the entries are counted as failed rather than written. Its message names
      # only the redacted url, since the url can hold credentials, and the start of the body.
      #
      # After a RuntimeError, such as a read timeout, it connects again for the next request, and
      # raises the error of this one even when connecting again fails, since only that error says
      # whether the server may have stored the request (see #wrote_nothing?). Not after a request it
      # could not send (see #not_sent?), such as a Net::OpenTimeout: connecting again straight away
      # would fail the same way, so that a server that cannot be reached would hold up each request
      # for twice its open_timeout.
      def process_request(request, body = nil)
        if body
          request.body = compress ? compress_data(body) : body
        end
        request.basic_auth(@username, @password) if @username
        # Net::HTTP sends a request on a connection that is not started, such as one that #close
        # closed, on a new connection that it closes after the response. Starting it keeps the
        # connection for the requests that follow, such as once a removed appender is added again.
        # A new one is built first when the appender has none, since #close forgot the one it
        # inherited in a forked child.
        http = @http || build_http
        http.start unless http.started?
        response = http.request(request)
        return accepted(response) if response.is_a?(Net::HTTPSuccess)

        raise ResponseError.new(
          "Bad HTTP response from: #{redacted_url} code: #{response.code}, " \
          "#{response.body.to_s[0, MAX_LOGGED_RESPONSE_BODY].inspect}",
          code: response.code.to_i,
          body: response.body
        )
      rescue RuntimeError => e
        reconnect unless not_sent?(e)
        raise e
      end

      # Returns true, for a request that the server accepted, answering with a 2xx status. A subclass
      # whose server reports in the body of such a response that it stored only part of the request
      # reads it here, as Metric::Otlp does for an OTLP partial success.
      def accepted(_response)
        true
      end

      # Connects again after a request failed. A failure to connect is reported to the internal
      # logger, and left to the next request, which connects again when the connection is not open.
      def reconnect
        reopen
      rescue StandardError => e
        logger.warn("Could not connect again to #{redacted_url}", e)
      end
    end
  end
end
