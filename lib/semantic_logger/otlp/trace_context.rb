module SemanticLogger
  module Otlp
    # The trace that a log entry was logged in, to link its OTLP log record to it: from the span that
    # was current on the thread that logged it, when the opentelemetry-api gem is loaded, which this
    # never requires; or else from the named tags `trace_id` and `span_id` that the application set,
    # as hex text.
    #
    # It knows how the span is captured, and how the ids are read back from the entry.
    class TraceContext
      # The key that CAPTURE keeps the ids of the current span under (see Log#capture).
      KEY = :otlp_trace_context

      # Keeps the hex trace id, hex span id, and trace flags of the current span on the entry, when the
      # OpenTelemetry API is loaded and its current span is valid. Registered with SemanticLogger.on_log,
      # so that it runs on the thread that logs, from a constant, so that it is registered once.
      # Shareable, so that entries logged in a Ractor other than the main one are linked too (see
      # Logger.subscribe).
      CAPTURE = Utils.make_shareable(lambda do |log|
        next unless defined?(::OpenTelemetry::Trace)

        context = ::OpenTelemetry::Trace.current_span.context
        next unless context.valid?

        log.capture(KEY, [context.hex_trace_id, context.hex_span_id, context.trace_flags.sampled? ? 1 : 0])
      rescue StandardError
        # Such as in a Ractor whose OpenTelemetry API cannot be reached: the record is then linked
        # through the named tags, if any, rather than the log call failing.
        nil
      end)

      # The appenders whose formatter writes the trace, so that CAPTURE is subscribed while there is
      # any (see .register and Subscriber#formatter=), by identity, since an appender may define #==.
      @owners = {}.compare_by_identity
      @mutex  = Mutex.new

      # Seconds that .register and .unregister wait in a signal trap for the thread that does it for
      # them (see TrapSafe.hand_off).
      TRAP_WAIT_SECONDS = 0.1

      # Subscribes CAPTURE with SemanticLogger.on_log, for an appender whose formatter writes the trace,
      # such as Formatters::Otlp or Formatters::Json, unless another already did. Registering the same
      # appender again changes nothing, other than subscribing CAPTURE again after the subscribers were
      # cleared, such as by Logger.clear_subscribers. Each appender that registers unregisters once
      # closed (see Subscriber#close).
      #
      # Trap-safe: in a signal trap, where Ruby does not allow a Mutex to be locked, such as one that
      # adds an appender, a new thread registers it (see TrapSafe.hand_off).
      def self.register(owner)
        exclusively do
          SemanticLogger.on_log(CAPTURE)
          @owners[owner] = true
        end
      end

      # Unsubscribes CAPTURE once no appender that registered uses it, so that no log call captures a
      # trace context that no appender reads. Unregistering an appender that is not registered changes
      # nothing. Trap-safe, as .register is.
      def self.unregister(owner)
        exclusively do
          next unless @owners.delete(owner)

          SemanticLogger::Logger.unsubscribe(CAPTURE) if @owners.empty?
        end
      end

      # Returns [true|false] whether the appender is registered.
      def self.registered?(owner)
        @owners.key?(owner)
      end

      # Runs the block holding the Mutex, or in a signal trap, on a new thread, waiting for it at most
      # TRAP_WAIT_SECONDS.
      def self.exclusively(&block)
        return if TrapSafe.try_synchronize(@mutex, &block)

        TrapSafe.hand_off(TRAP_WAIT_SECONDS) { @mutex.synchronize(&block) }
        nil
      end

      # The named tags that hold the ids, when the application sets them.
      TRACE_ID_TAG = "trace_id".freeze
      SPAN_ID_TAG  = "span_id".freeze

      TRACE_ID = /\A\h{32}\z/
      SPAN_ID  = /\A\h{16}\z/

      # Returns [String] the trace id, as 32 lower case hex digits.
      attr_reader :trace_id

      # Returns [String|nil] the span id, as 16 lower case hex digits.
      attr_reader :span_id

      # Returns [Integer|nil] the trace flags, 1 when the span is sampled.
      attr_reader :flags

      # Returns [Array<String>] the names of the named tags that the ids were taken from, which are
      # then not attributes of their own.
      attr_reader :tags

      # Returns [TraceContext|nil] the trace of the entry: that of the span captured when it was
      # logged, or else that of its named tags, when its `trace_id` holds a valid trace id, of 32 hex
      # digits, not all zero. Its `span_id` is taken with it only when it holds a valid span id, of
      # 16 hex digits, not all zero. Nil when neither is there.
      def self.of(log)
        trace_id, span_id, flags = log.captured(KEY)
        return new(trace_id, span_id, flags, []) if trace_id

        from_named_tags(log.named_tags)
      end

      def self.from_named_tags(named_tags)
        return unless named_tags.is_a?(Hash) && !named_tags.empty?

        trace_tag, trace_id = id_tag(named_tags, TRACE_ID_TAG, TRACE_ID)
        return unless trace_tag

        span_tag, span_id = id_tag(named_tags, SPAN_ID_TAG, SPAN_ID)
        new(trace_id, span_id, nil, [trace_tag, span_tag].compact)
      end

      # Returns [Array] the key of the named tag of that name, a String or Symbol, and its value, lower
      # case, when it is a valid id; nil otherwise.
      def self.id_tag(named_tags, name, format)
        key = named_tags.key?(name) ? name : name.to_sym
        value = named_tags[key]
        return unless value.is_a?(String) && value.match?(format) && value.match?(/[^0]/)

        [key, value.downcase]
      end

      private_class_method :new, :from_named_tags, :id_tag, :exclusively

      def initialize(trace_id, span_id, flags, tags)
        @trace_id = trace_id
        @span_id  = span_id
        @flags    = flags
        @tags     = tags
      end
    end
  end
end
