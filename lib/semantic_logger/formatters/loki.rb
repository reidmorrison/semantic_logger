require "json"
require "semantic_logger/formatters/loki/labels"

module SemanticLogger
  module Formatters
    class Loki < Base
      attr_accessor :stream, :payload_value

      # The names of the structured metadata that this formatter writes itself for the fields of an
      # entry, to which the labels named by `structured_metadata:` are added (see #initialize). A
      # payload key that Loki would store under one of this formatter's own names is written with
      # PAYLOAD_PREFIX, as in `payload_duration`, whether or not the entry has that field, so that
      # each name always holds this formatter's value. Loki keeps one value of a name: the last of
      # a name written twice, but of names that it stores alike, such as `metric.value` and
      # `metric_value` (see .own_name), the one it had to change. So the payload's value would
      # otherwise be lost, or replace this formatter's.
      OWN_KEYS = %w[
        metric metric_value dimensions duration duration_human exception_name exception_message
        stack_trace
      ].freeze

      # The labels that `structured_metadata:` can write to the structured metadata instead (see
      # #initialize).
      STRUCTURED_METADATA = %i[pid thread].freeze

      # A run of characters other than ASCII letters and digits, which Loki replaces with one
      # underscore in the name of structured metadata. So Loki stores `metric.value`,
      # `metric__value`, and `metric` followed by a zero width space and `value` all as
      # `metric_value`.
      LOKI_SEPARATOR = /[^A-Za-z0-9]+/

      # Returns [Regexp] a pattern that matches a name that Loki stores as one of the supplied
      # names: each underscore of a name stands for a LOKI_SEPARATOR. Matching it allocates
      # nothing, unlike comparing #loki_name with each name, and nearly every payload key is
      # checked against it.
      def self.own_name(names)
        /\A(?:#{names.map { |name| name.gsub('_', LOKI_SEPARATOR.source) }.join('|')})\z/
      end

      # Matches a name that Loki stores as one of OWN_KEYS.
      OWN_NAME = own_name(OWN_KEYS)

      # Matches a name that holds an ASCII letter or digit. Loki rejects the whole push for a
      # structured metadata name without one, such as an empty name, `-`, or `_`, since it would
      # store it as an empty name or as `_`.
      LETTER_OR_DIGIT = /[A-Za-z0-9]/

      # The prefix of a payload key named like one of this formatter's own structured metadata
      # names, or without a letter or digit. The :logfmt and :open_telemetry formatters write
      # `payload.`, which Loki would store as `payload_`.
      PAYLOAD_PREFIX = "payload_".freeze

      # A name that starts with a digit, which Loki stores with `key_` before it.
      LEADING_DIGIT = /\A[0-9]/

      # The most labels that Loki accepts for a stream, its `max_label_names_per_series`, the
      # longest label name, its `max_label_name_length`, and the longest label value, its
      # `max_label_value_length`, in bytes, unless a Loki tenant's `limits_config` raises them. See
      # #initialize.
      attr_reader :max_label_names_per_series, :max_label_name_length, :max_label_value_length

      # The labels that are written to the structured metadata instead (see #initialize): a frozen
      # Array of :pid, :thread, both, or neither.
      attr_reader :structured_metadata

      # Parameters
      #   structured_metadata: [Array<Symbol>]
      #     The labels to write to the structured metadata instead, as Strings: `:pid`, the process
      #     id, `:thread`, the thread name, both, or neither. Loki advises against labels like these,
      #     whose values are many and change: each process, and each of its threads, adds a stream,
      #     which Loki indexes and stores apart. As structured metadata, a query can still filter on
      #     them, as in `{application="shop"} | thread="worker-1"`. Their names are then among this
      #     formatter's own: a payload key of that name is written with PAYLOAD_PREFIX, as a key
      #     named like one of its other fields is, and a named tag or context key of that name is
      #     written as a label with a number, as in `thread_2`, since Loki would show the structured
      #     metadata as `thread_extracted` beside a label of its name.
      #     Structured metadata needs a Loki that accepts it, with schema v13 and
      #     `allow_structured_metadata`, which is on by default since Loki 3.0. Any other Loki
      #     rejects each entry that has structured metadata, which with `:pid` is every entry.
      #     Default: neither, so that both are labels, with a deprecation warning, since Semantic
      #     Logger v6 writes both to the structured metadata by default. Supply [] to keep both as
      #     labels without it.
      #
      #   max_label_names_per_series: [Integer]
      #     The most labels that Loki accepts for a stream. Loki rejects the whole push, with every
      #     entry in it, for a stream with more, so a label past it, in the order they are written
      #     (see #build_stream), is written to the structured metadata instead.
      #     Default: 15, as Loki's `max_label_names_per_series`
      #   max_label_name_length: [Integer]
      #     The longest label name, in bytes, that Loki accepts. A label with a longer name is
      #     written to the structured metadata instead.
      #     Default: 1024, as Loki's `max_label_name_length`
      #   max_label_value_length: [Integer]
      #     The longest label value, in bytes, that Loki accepts. A label with a longer value, such as
      #     many tags, is written to the structured metadata instead.
      #     Default: 2048, as Loki's `max_label_value_length`
      #
      #   Set each limit, an Integer of 1 or more, to the limit of the same name in the
      #   `limits_config` of a Loki tenant that raises it.
      #
      #   See Formatters::Base for the other options.
      #
      # The instance variables that are not options are named for Loki, as in @loki_pid_label, so
      # that they are not names that a subclass may already use for its own.
      def initialize(structured_metadata: nil, max_label_names_per_series: 15, max_label_name_length: 1024,
                     max_label_value_length: 2048, **args)
        super(**args)
        @structured_metadata        = structured_metadata_option(structured_metadata)
        @loki_metadata_labels       = @structured_metadata.map(&:name).freeze
        @loki_own_keys              = (OWN_KEYS + @loki_metadata_labels).freeze
        @loki_own_name              = @loki_metadata_labels.empty? ? OWN_NAME : Loki.own_name(@loki_own_keys)
        @loki_pid_label             = !@structured_metadata.include?(:pid)
        @loki_thread_label          = !@structured_metadata.include?(:thread)
        @max_label_names_per_series = label_limit(:max_label_names_per_series, max_label_names_per_series)
        @max_label_name_length      = label_limit(:max_label_name_length, max_label_name_length)
        @max_label_value_length     = label_limit(:max_label_value_length, max_label_value_length)
      end

      # Returns [String|nil] the name under which to write a value, among names, a Hash of the
      # names already written and their values: the name itself when it is free; when another value
      # has it, the first name with a number after it that is free, as in `request_id_2`, so that
      # both values are kept, since Loki keeps one value of a name; or nil when the block returns
      # true for the value of that name, or of a numbered name before it, as the same value, so
      # that it is written once. Both the labels (see Labels) and the structured metadata (see
      # #write_moved_labels) are named so.
      #
      # The number is added to the stem, which is the name unless given. For structured metadata
      # it is the name without a trailing underscore, so that `payload_` is numbered `payload_2`,
      # as Loki would store `payload__2`. A name in reserved, which a value outside names has, is
      # never free, nor the same, such as the label `thread` while the thread is structured
      # metadata (see Labels).
      def self.free_name(names, name, stem = name, reserved: nil)
        candidate = name
        number    = 1
        while names.key?(candidate) || reserved&.include?(candidate)
          return if names.key?(candidate) && yield(names[candidate])

          number   += 1
          candidate = "#{stem}_#{number}"
        end
        candidate
      end

      # Returns [String] the name that Loki stores structured metadata of the supplied name under:
      # in UTF-8 without invalid bytes, as Utils.to_json writes it, with each run of characters
      # other than ASCII letters and digits replaced with one underscore, and `key_` before a name
      # that starts with a digit.
      #
      # The `key_` cannot change which name a prefixed key gets: that name starts with
      # PAYLOAD_PREFIX, and only the other keys it is checked against can start with a digit. It is
      # there so that this returns the name Loki stores for any name, not only for the names it is
      # used for here.
      def self.loki_name(name)
        name = Utils.encode_utf8_string(name).gsub(LOKI_SEPARATOR, "_")
        name.match?(LEADING_DIGIT) ? "key_#{name}" : name
      end

      # Returns [String] a single JSON log
      def call(log, logger)
        self.logger = logger
        self.log = log

        Utils.to_json({streams: [loki_stream]})
      end

      # Returns [String] a JSON batch of logs
      def batch(logs, logger)
        self.logger = logger

        streams = logs.map do |log|
          self.log = log
          loki_stream
        end

        Utils.to_json({streams: streams})
      end

      private

      # Returns [Hash] the stream of the current log entry, which #build_stream builds.
      #
      # A subclass that overrides #build_stream without calling super, as one written for v5.2
      # may, does not finish the stream's labels, so they are finished here (see
      # #finish_loki_stream) when the stream it returns has the current stream's labels. So it
      # still writes each named tag and context key whose name is taken, reserved, or replaced,
      # writes the process id and the thread name to the structured metadata when
      # structured_metadata names them, and moves the labels past Loki's limits. The labels are
      # finished again when a subclass added one after its #build_stream called super (see
      # Labels#finished?), such as one under a Symbol whose name another label has. The structured
      # metadata written is that of the entry it returns (see #entry_metadata). A formatter of
      # this class itself finishes them in #build_stream, and so skips this.
      def loki_stream
        return build_stream if instance_of?(Loki)

        built = build_stream
        finish_loki_stream(entry_metadata(built)) if current_labels?(built) && !loki_labels.finished?
        built
      end

      # Whether the stream that #build_stream returned has the current stream's labels, a Hash,
      # which a subclass's own stream may not, such as one under String keys.
      def current_labels?(built)
        labels = built[:stream] if built.is_a?(Hash)
        labels.is_a?(Hash) && stream.is_a?(Hash) && labels.equal?(stream[:stream])
      end

      # Returns [Hash|nil] the structured metadata of the entry of the stream that #build_stream
      # returned, the third of its values: payload_value, unless a subclass wrote a copy of it, as
      # in `payload_value.merge(...)`, or nil when it wrote none.
      def entry_metadata(built)
        values = built[:values]
        entry  = values[0] if values.is_a?(Array)
        entry[2] if entry.is_a?(Array)
      end

      # The labels are written in this order: this formatter's own (pid, application, environment,
      # host, level, thread, and tags, without those that structured_metadata names), each named
      # tag, and each value of the context, under their own names, and then each named tag and
      # context key whose name another label has, or that Loki does not accept, or that
      # structured_metadata names, under another name, or not at all (see Labels#add). So every
      # label written under its own name keeps it. Their names are Strings, so that a named tag or
      # context key, whether a Symbol or a String, is found among them by name, as Loki finds it.
      # The labels past Loki's limits are then taken out and written to the structured metadata
      # (see #finish_loki_stream).
      def build_stream
        self.stream = {stream: @loki_pid_label ? {"pid" => pid} : {}, values: [[]]}

        application
        environment
        host
        level
        thread
        tags
        named_tags
        context
        time
        message
        payload
        metric
        duration
        exception
        finish_loki_stream

        stream[:values][0] << payload_value
        stream
      end

      def host
        stream[:stream]["host"] = logger.host if log_host && logger&.host
      end

      def application
        stream[:stream]["application"] = logger.application if log_application && logger&.application
      end

      def environment
        stream[:stream]["environment"] = logger.environment if log_environment && logger&.environment
      end

      def level
        stream[:stream]["level"] = log.level
      end

      def thread
        stream[:stream]["thread"] = log.thread_name if @loki_thread_label && log.thread_name
      end

      def tags
        stream[:stream]["tags"] = log.tags if log.tags.respond_to?(:empty?) && !log.tags.empty?
      end

      def named_tags
        return unless log.named_tags.respond_to?(:empty?) && !log.named_tags.empty?

        stream_labels = loki_labels
        log.named_tags.each_pair { |key, value| stream_labels.add(key, value) }
      end

      def context
        return unless log.context && !log.context.empty?

        stream_labels = loki_labels
        log.context.each { |key, value| stream_labels.add(key, value) }
      end

      # Returns [Labels] the labels of the current stream, to which the named tags and the context
      # are added, created for it unless they are already its labels. So a subclass whose own
      # #build_stream does not create them, as in v5.2, still adds the named tags and the context.
      # Each label value is converted by #loki_value, so a subclass that overrides it converts the
      # labels' values too. This formatter's own methods write every label under a String, while a
      # subclass's may write one under a Symbol, as v5.2 did, so only a subclass's labels are told
      # that they may have a Symbol name (see Labels#initialize).
      #
      # This method and its instance variables are named for Loki, so that they are not names that
      # a subclass may already use for its own, such as #labels or @labels.
      def loki_labels
        labels = stream[:stream]
        return @loki_labels if @loki_labels&.of?(labels)

        @loki_value_of ||= method(:loki_value)
        @loki_labels = Labels.new(labels, @loki_value_of, max_label_names_per_series, max_label_name_length,
                                  max_label_value_length, reserved: @loki_metadata_labels, symbols: !instance_of?(Loki))
      end

      # Finishes the current stream: finishes its labels (see Labels#finish), which writes the
      # named tags and context keys whose names are taken, reserved, or replaced, and takes out the
      # labels past Loki's limits; then writes the process id and the thread name to the structured
      # metadata, the supplied Hash, when structured_metadata names them (see
      # #write_pid_and_thread), and after them, the labels taken out (see #write_moved_labels).
      #
      # When a subclass's own #build_stream writes no structured metadata, so that there is none
      # (see #loki_stream), there is nowhere to write them, so the labels past the limits, and the
      # process id and thread name, are left out, rather than having Loki reject the push.
      def finish_loki_stream(metadata = payload_value)
        moved = loki_labels.finish
        return unless metadata.is_a?(Hash)

        write_pid_and_thread(metadata)
        write_moved_labels(moved, metadata) if moved
      end

      # Adds the labels past Loki's limits (see #finish_loki_stream) to the structured metadata,
      # after the others, each under its name as Loki stores it, such as `a_b` for the label `a__b`
      # (see #loki_name), and with PAYLOAD_PREFIX when a payload key with that name would have it,
      # as for `duration` or `_` (see #prefixed_key?). When the structured metadata already has
      # that name, as Loki stores it, the label is written with a number after it, as a label is
      # (see .free_name), rather than with the prefix again, as a payload key is (see
      # #add_prefixed), or not at all when the only key that Loki stores under that name has the
      # same value (see #metadata_names).
      def write_moved_labels(moved, metadata)
        names = metadata_names(metadata)
        moved.each do |name, value|
          name = prefixed_key?(name) ? prefixed_name(name) : loki_name(name)
          name = Loki.free_name(names, name, name.delete_suffix("_")) do |held|
            !held.nil? && loki_value(held) == value
          end
          names[name] = metadata[name] = value if name
        end
      end

      # Returns [Hash] each name of the structured metadata, as Loki stores it (see #loki_name),
      # with its value when one key alone has that name, such as `a.b` for `a_b`, or else with nil,
      # which no value is the same as (see #write_moved_labels): of the keys that it stores alike,
      # Loki keeps the value of one whose name it changed, such as `a.b` over `a_b`.
      def metadata_names(metadata)
        names = {}
        metadata.each_pair do |key, value|
          name        = loki_name(key.to_s)
          names[name] = names.key?(name) ? nil : value
        end
        names
      end

      def time
        stream[:values][0] << format_time(log)
      end

      def message
        stream[:values][0] << (log.message ? log.cleansed_message : "")
      end

      def format_time(log)
        log.time.strftime("%s%N")
      end

      def payload
        self.payload_value = if !log.payload?
                               {}
                             elsif log.payload.is_a?(Hash)
                               payload_metadata(log.payload)
                             else
                               # A log call can supply any value as the payload, such as a String
                               # parsed from a request body.
                               {"payload" => loki_value(log.payload)}
                             end
      end

      # Every value is a String, since structured metadata only holds Strings: Loki rejects the
      # whole push, with every entry in it, when one holds a number or null. The dimensions are a
      # single value, as JSON.
      def metric
        return unless log.metric

        payload_value[:metric]       = loki_value(log.metric)
        payload_value[:metric_value] = number_text(log.metric_amount) if log.metric_amount
        payload_value[:dimensions]   = loki_value(log.dimensions) if log.dimensions?
      end

      def duration
        return unless log.duration

        payload_value[:duration] = number_text(log.duration)
        payload_value[:duration_human] = log.duration_human
      end

      # Returns [String] the number as LogQL reads it, to compare it or `unwrap` it: an Integer as
      # it is, and any other number as a Float, which is how LogQL holds it. A Rational's own text,
      # such as `3/2`, would make every LogQL query that unwraps it fail, and a BigDecimal's, such
      # as `0.25e1`, is not how anyone writes a number.
      def number_text(number)
        number.is_a?(Integer) ? number.to_s : number.to_f.to_s
      end

      # The stack trace is one line per frame, followed by each exception that caused it, as the
      # text formatters write it.
      #
      # The name and message are Strings too: the class's name, or, for an anonymous class, which
      # has none, the class as the text formatters write it, such as `#<Class:0x000...>`. A
      # #message that returns nil, or raises, is replaced as Utils.exception_message replaces it.
      def exception
        return unless log.exception

        payload_value.merge!(
          exception_name:    Utils.exception_name(log.exception),
          exception_message: Utils.exception_message(log.exception),
          stack_trace:       exception_backtrace
        )
      end

      # Writes the process id and the thread name to the structured metadata, the supplied Hash, as
      # Strings, when structured_metadata names them (see #initialize).
      def write_pid_and_thread(metadata)
        metadata[:pid]    = pid.to_s unless @loki_pid_label
        metadata[:thread] = log.thread_name if !@loki_thread_label && log.thread_name
      end

      # Returns [Hash] the payload as structured metadata, with String keys and values, since Loki
      # only accepts Strings.
      #
      # A key that Loki would store as one of this formatter's own names (see #prefixed_key?), or
      # that it would reject (see LETTER_OR_DIGIT), is written with PAYLOAD_PREFIX, after the other
      # keys (see #add_prefixed).
      def payload_metadata(hash)
        metadata = {}
        prefixed = nil
        hash.each_pair do |key, value|
          name = key.to_s
          if prefixed_key?(name)
            (prefixed ||= []) << [name, value]
          else
            metadata[name] = loki_value(value)
          end
        end
        add_prefixed(metadata, prefixed) if prefixed
        metadata
      end

      # Adds each of the payload's keys named like this formatter's own, or without an ASCII letter
      # or digit, with PAYLOAD_PREFIX, under the name Loki stores it as (see #loki_name), such as
      # `payload_metric_value` for `metric.value`, and `payload_` for an empty key or `-`, and with
      # the prefix again while another key has that name once Loki has stored it. Loki keeps only
      # one value of the names that it stores alike, so this keeps the value of each of these keys.
      # Other payload keys that Loki stores alike, such as `a.b` and `a_b`, still keep only one.
      #
      # A key that is exactly one of this formatter's own names, OWN_KEYS and those that
      # structured_metadata names, is named first, so that `payload_metric_value` holds the
      # payload's `metric_value`, whatever the order of the keys, and `metric.value` is prefixed
      # again.
      def add_prefixed(metadata, prefixed)
        taken = Set.new(metadata.each_key) { |name| loki_name(name) }
        exact, lookalikes = prefixed.partition { |name, _value| @loki_own_keys.include?(name) }
        (exact + lookalikes).each do |name, value|
          name = prefixed_name(name)
          name = PAYLOAD_PREFIX + name while taken.include?(name)
          taken << name
          metadata[name] = loki_value(value)
        end
      end

      # Returns [String] the name with PAYLOAD_PREFIX, as Loki stores it.
      #
      # Joining the prefix with the name as Loki stores it gives the name Loki stores the joined
      # name as: a name like one of this formatter's own starts with a letter, and one without a
      # letter or digit is stored as an empty name or as `_`, which Loki would write as one
      # underscore with the prefix's, so that underscore is left out.
      def prefixed_name(name)
        PAYLOAD_PREFIX + loki_name(name).delete_prefix("_")
      end

      # Returns [String] the name that Loki stores structured metadata of the supplied name under
      # (see .loki_name).
      def loki_name(name) = Loki.loki_name(name)

      # Whether the payload key is written with PAYLOAD_PREFIX: Loki would store it as one of this
      # formatter's own names, OWN_KEYS and those that structured_metadata names (see .own_name),
      # or it has no ASCII letter or digit (see LETTER_OR_DIGIT).
      #
      # A name with characters outside ASCII is matched as Utils.to_json writes it: in UTF-8,
      # without invalid bytes, which matching it as it is could raise for. So a key of invalid
      # bytes alone is prefixed, since it is written as an empty name.
      def prefixed_key?(name)
        name = Utils.encode_utf8_string(name) unless name.ascii_only?
        name.match?(@loki_own_name) || !name.match?(LETTER_OR_DIGIT)
      end

      # Returns [String] the value as Loki accepts it, as both the labels (see #loki_labels) and
      # the structured metadata write it.
      #
      # A structure is written once, as JSON, depth-limited and repaired by Utils.to_json.
      # Encoding each nested level into a String that the next level encodes again doubled the
      # escaping at every level, so a request parameter 30 levels deep produced gigabytes. A
      # structure's #to_s is its #inspect, which would also expose the instance variables of any
      # object it holds.
      def loki_value(value)
        if value.is_a?(String)
          value
        elsif Utils.structure?(value)
          Utils.to_json(value)
        else
          value.to_s
        end
      end

      # Returns [Array<Symbol>] the labels to write to the structured metadata (see #initialize):
      # none when the option is not supplied, with a deprecation warning, since v6 writes both
      # there by default.
      # Raises ArgumentError for anything but a list of STRUCTURED_METADATA, so that a mistake
      # surfaces here rather than as a label left where it was.
      def structured_metadata_option(labels)
        if labels.nil?
          Deprecation.warn(
            "The :loki formatter writes pid and thread as stream labels by default, which changes in v6. " \
            "Give it structured_metadata: [] to keep them as labels, or structured_metadata: [:pid, :thread] to " \
            "write them as structured metadata, which needs a Loki that accepts it (schema v13 with " \
            "allow_structured_metadata, the default since Loki 3.0), as in " \
            "add_appender(appender: :loki, formatter: {loki: {structured_metadata: [:pid, :thread]}}). See " \
            "https://logger.reidmorrison.com/appenders.html#pid-and-thread-as-structured-metadata"
          )
          return [].freeze
        end
        return labels.uniq.freeze if labels.is_a?(Array) && (labels - STRUCTURED_METADATA).empty?

        raise(ArgumentError, "structured_metadata must be a list of :pid and :thread, not #{labels.inspect}")
      end

      # Returns [Integer] the supplied limit (see #initialize).
      # Raises ArgumentError for any value other than an Integer of 1 or more, so that a mistake
      # surfaces here rather than on every log entry. A limit of 0 would leave every stream without a
      # label, which Loki stores as the one stream `service_name="unknown_service"`, or rejects when
      # it does not add `service_name`.
      def label_limit(option, value)
        return value if value.is_a?(Integer) && value.positive?

        raise(ArgumentError, "#{option} must be an Integer of 1 or more, not #{value.inspect}")
      end
    end
  end
end
