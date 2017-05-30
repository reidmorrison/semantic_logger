require 'socket'
module SemanticLogger
  module Metrics
    class Udp < Subscriber
      attr_accessor :server, :separator, :udp_flags
      attr_reader :socket

      # Write metrics to in JSON format to Udp
      #
      # Parameters:
      #   server: [String]
      #     Host name and port to write UDP messages to
      #     Example:
      #       localhost:8125
      #
      #   udp_flags: [Integer]
      #     Should be a bitwise OR of Socket::MSG_* constants.
      #     Default: 0
      #
      # Limitations:
      # * UDP packet size is limited by the connected network and any routers etc
      #   that the message has to traverse. See https://en.wikipedia.org/wiki/Maximum_transmission_unit
      #
      # Example:
      #   SemanticLogger.on_metric(
      #     appender: :udp,
      #     server:   'localhost:8125'
      #   )
      def initialize(options = {}, &block)
        options    = options.dup
        @server    = options.delete(:server)
        @udp_flags = options.delete(:udp_flags) || 0
        raise(ArgumentError, 'Missing mandatory argument: :server') unless @server

        super(options, &block)
        reopen
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      def reopen
        close
        @socket    = UDPSocket.new
        host, port = server.split(':')
        @socket.connect(host, port)
      end

      def call(log)
        metric = log.metric
        if duration = log.duration
          @statsd.timing(metric, duration)
        else
          amount = (log.metric_amount || 1).round
          if amount < 0
            amount.times { @statsd.decrement(metric) }
          else
            amount.times { @statsd.increment(metric) }
          end
        end
        @socket.send(data, udp_flags)
      end

      # Flush is called by the semantic_logger during shutdown.
      def flush
        @socket.flush if @socket
      end

      # Close is called during shutdown, or with reopen
      def close
        @socket.close if @socket
      end

      private

      # Returns [SemanticLogger::Formatters::Default] formatter default for this Appender
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end

    end
  end
end
