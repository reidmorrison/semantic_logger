require "json"

module SemanticLogger
  module Formatters
    class Loki < Base
      attr_accessor :stream, :payload_value

      # The names of the structured metadata that this formatter writes itself. A payload key that
      # Loki would store under one of these names is written with PAYLOAD_PREFIX, as in
      # `payload_duration`, whether or not the entry has that field, so that each name always holds
      # this formatter's value. Loki keeps one value of a name: the last of a name written twice,
      # but of names that it stores alike, such as `metric.value` and `metric_value` (see
      # OWN_NAME), the one it had to change. So the payload's value would otherwise be lost, or
      # replace this formatter's.
      OWN_KEYS = %w[
        metric metric_value dimensions duration duration_human exception_name exception_message
        stack_trace
      ].freeze

      # A run of characters other than ASCII letters and digits, which Loki replaces with one
      # underscore in the name of structured metadata. So Loki stores `metric.value`,
      # `metric__value`, and `metric` followed by a zero width space and `value` all as
      # `metric_value`.
      LOKI_SEPARATOR = /[^A-Za-z0-9]+/

      # Matches a name that Loki stores as one of OWN_KEYS: each underscore of an own name stands
      # for a LOKI_SEPARATOR. Matching it allocates nothing, unlike comparing #loki_name with each
      # own name, and nearly every payload key is checked against it.
      OWN_NAME = /\A(?:#{OWN_KEYS.map { |key| key.gsub('_', LOKI_SEPARATOR.source) }.join('|')})\z/

      # Matches a name that holds an ASCII letter or digit. Loki rejects the whole push for a
      # structured metadata name without one, such as an empty name, `-`, or `_`, since it would
      # store it as an empty name or as `_`.
      LETTER_OR_DIGIT = /[A-Za-z0-9]/

      # The prefix of a payload key named like one of OWN_KEYS, or without a letter or digit. The
      # :logfmt and :open_telemetry formatters write `payload.`, which Loki would store as
      # `payload_`.
      PAYLOAD_PREFIX = "payload_".freeze

      # A name that starts with a digit, which Loki stores with `key_` before it.
      LEADING_DIGIT = /\A[0-9]/

      # Matches a label name that Loki accepts: an ASCII letter or an underscore, followed by ASCII
      # letters, digits, and underscores. Loki rejects the whole push for any other, such as
      # `request-id`, `1st`, or an empty name, with "couldn't parse labels".
      LABEL_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      # The name of a label whose key is empty, with the prefix that Loki puts before a name that
      # starts with a digit.
      EMPTY_LABEL_NAME = "key_".freeze

      # The label that Loki adds to a stream that does not have it, and does not count toward
      # max_label_names_per_series, even when the stream has it.
      SERVICE_NAME = "service_name".freeze

      # The most labels that Loki accepts for a stream, its `max_label_names_per_series`, the
      # longest label name, its `max_label_name_length`, and the longest label value, its
      # `max_label_value_length`, in bytes, unless a Loki tenant's `limits_config` raises them. See
      # #initialize.
      attr_reader :max_label_names_per_series, :max_label_name_length, :max_label_value_length

      # Parameters
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
      #   Set each to the limit of the same name in the `limits_config` of a Loki tenant that raises
      #   it.
      #
      #   See Formatters::Base for the other options.
      def initialize(max_label_names_per_series: 15, max_label_name_length: 1024, max_label_value_length: 2048,
                     **args)
        super(**args)
        @max_label_names_per_series = label_limit(:max_label_names_per_series, max_label_names_per_series)
        @max_label_name_length      = label_limit(:max_label_name_length, max_label_name_length)
        @max_label_value_length     = label_limit(:max_label_value_length, max_label_value_length)
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
      # may, does not write the named tags and context keys whose names are taken or replaced, so
      # they are written here (see #renamed_labels) when the stream it returns has the current
      # stream's labels. After the formatter's own #build_stream, this writes only a label that a
      # subclass wrote under a Symbol since (see #string_label_names), so a formatter of this
      # class itself skips it.
      def loki_stream
        return build_stream if instance_of?(Loki)

        @renamed_labels = nil
        built           = build_stream
        renamed_labels if current_labels?(built)
        built
      end

      # Whether the stream that #build_stream returned has the current stream's labels, a Hash,
      # which a subclass's own stream may not, such as one under String keys.
      def current_labels?(built)
        labels = built[:stream] if built.is_a?(Hash)
        labels.is_a?(Hash) && stream.is_a?(Hash) && labels.equal?(stream[:stream])
      end

      # The labels are written in this order: this formatter's own (pid, application, environment,
      # host, level, thread, and tags), each named tag, and each value of the context, under their
      # own names, and then each named tag and context key whose name another label has, or that
      # Loki does not accept, under another name, or not at all (see #add_label). So every label
      # written under its own name keeps it. Their names are Strings, so that a named tag or context
      # key, whether a Symbol or a String, is found among them by name, as Loki finds it. The labels
      # past Loki's limits are then written to the structured metadata (see #limit_labels).
      def build_stream
        self.stream     = {stream: {"pid" => pid}, values: [[]]}
        @renamed_labels = nil
        @moved_labels   = nil

        application
        environment
        host
        level
        thread
        tags
        named_tags
        context
        renamed_labels
        limit_labels
        time
        message
        payload
        metric
        duration
        exception
        moved_labels

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
        stream[:stream]["thread"] = log.thread_name if log.thread_name
      end

      def tags
        stream[:stream]["tags"] = log.tags if log.tags.respond_to?(:empty?) && !log.tags.empty?
      end

      # The labels' names are made Strings first (see #string_label_names), so that #add_label
      # finds each of them by name.
      def named_tags
        return unless log.named_tags.respond_to?(:empty?) && !log.named_tags.empty?

        string_label_names
        log.named_tags.each_pair { |key, value| add_label(key, value) }
      end

      # See #named_tags.
      def context
        return unless log.context && !log.context.empty?

        string_label_names
        log.context.each { |key, value| add_label(key, value) }
      end

      # Adds a label from the named tags or the context, with its value as Loki stores it (see
      # #loki_value), unless the value is nil, which Loki would store as the text "null".
      #
      # Loki rejects the whole push for a label name it does not accept (see LABEL_NAME), so such a
      # name is replaced (see #label_name_for). Loki keeps one value of a label name, so a label
      # whose name another label already has is written once when that label has the same value,
      # as Loki stores it, and otherwise under another name. Both are added after the others, by
      # #renamed_labels, so that the name they get is not one that a later label has as its own.
      def add_label(key, value)
        return if value.nil?

        name   = key.is_a?(Symbol) ? key.name : key.to_s
        value  = loki_value(value)
        labels = stream[:stream]
        if !label_name?(name)
          (@renamed_labels ||= []) << [label_name_for(name), value]
        elsif !labels.key?(name)
          labels[name] = value
        else
          (@renamed_labels ||= []) << [name, value]
        end
      end

      # Whether Loki accepts the name as a label name. A name with characters outside ASCII never
      # is, and matching it could raise, when it holds invalid UTF-8.
      def label_name?(name)
        name.ascii_only? && name.match?(LABEL_NAME)
      end

      # Returns [String] a name that Loki accepts for a label whose name it does not: the name under
      # which Loki stores structured metadata of that name (see #loki_name), such as `request_id`
      # for `request-id`, and `key_1st` for `1st`, or EMPTY_LABEL_NAME for an empty name.
      def label_name_for(name)
        name = loki_name(name)
        name.empty? ? EMPTY_LABEL_NAME : name
      end

      # Adds the labels whose names are taken or were replaced (see #add_label), after the others,
      # so that a label written under its own name keeps it, in two passes: first each whose name
      # is free, and then each of the rest, with a number, or not at all when the label of that
      # name has the same value, as Loki stores it (see #write_label). So the number a label gets is
      # never the name that another of them is written under, such as `host_2` for a named tag
      # `host-2`, whatever the order of their keys. Only #write_label compares the values, so that
      # the value of each label a label is compared with is converted once.
      #
      # A label written under a Symbol since the named tags and the context were added, as by a
      # subclass, is first written under a String (see #string_label_names).
      def renamed_labels
        string_label_names
        return unless @renamed_labels

        labels  = stream[:stream]
        pending = @renamed_labels.reject do |name, value|
          next false if labels.key?(name)

          labels[name] = value
          true
        end
        @renamed_labels = nil
        pending.each { |name, value| write_label(name, value) }
      end

      # Writes each label whose name is not a String under its name as a String, in place and in
      # the same order: a subclass written for v5.2 may still write its own label under a Symbol,
      # as v5.2 did, such as `:host`, or the `{pid: pid}` of v5.2's #build_stream. Otherwise
      # #add_label would not find its name among the labels, and would write a named tag of that
      # name beside it, so the JSON would have the name twice, which json 3 refuses to write. When
      # a label written before it has its name, the later one is written as a named tag whose name
      # is taken is (see #renamed_labels), numbered unless it has the same value.
      #
      # It is called before the named tags and the context are added, and before the labels whose
      # names are taken or replaced are written, so that the labels are numbered in the order they
      # are written in (see #build_stream). This formatter's own methods write every label under a
      # String, so only a subclass, whose methods may write one under a Symbol, has its label
      # names checked, which Hash#any? does without allocating.
      def string_label_names
        return if instance_of?(Loki)

        labels = stream[:stream]
        return unless labels.any? { |name, _value| !name.is_a?(String) }

        written = labels.to_a
        labels.clear
        written.each do |name, value|
          name = name.is_a?(Symbol) ? name.name : name.to_s
          if labels.key?(name)
            (@renamed_labels ||= []) << [name, loki_value(value)]
          else
            labels[name] = value
          end
        end
      end

      # Writes a label under its name, unless another label already has that name (see
      # #free_name).
      def write_label(name, value)
        labels = stream[:stream]
        name   = free_name(labels, name, value)
        labels[name] = value if name
      end

      # Returns [String|nil] the name under which to write a value, among names, a Hash of the names
      # already written and their values: the name itself when it is free; when another value has
      # it, the first name with a number after it that is free, as in `request_id_2`, so that both
      # values are kept, since Loki keeps one value of a name; or nil when the value of that name,
      # or of a numbered name before it, is the same, once Loki stores it, so that it is written
      # once. A value that is not a String, such as the `level` Symbol or the `pid` Integer of this
      # formatter's own labels, is compared as Loki stores it.
      #
      # The number is added to the stem, which is the name unless given. For structured metadata it
      # is the name without a trailing underscore, so that `payload_` is numbered `payload_2`, as
      # Loki would store `payload__2`.
      def free_name(names, name, value, stem = name)
        candidate = name
        number    = 1
        while names.key?(candidate)
          return if loki_value(names[candidate]) == value

          number   += 1
          candidate = "#{stem}_#{number}"
        end
        candidate
      end

      # Moves each label for which Loki would reject the whole push, with every entry in it, to the
      # structured metadata (see #moved_labels), so that the push is accepted and the value kept: a
      # label whose name is longer than max_label_name_length, or whose value, as Loki stores it,
      # is longer than max_label_value_length, and each label past max_label_names_per_series, in
      # the order they are written (see #build_stream).
      #
      # As Loki 3.7.10 does, the labels with an empty value, which Loki leaves out, and
      # SERVICE_NAME, are not counted.
      def limit_labels
        labels = stream[:stream]
        return if labels.size <= max_label_names_per_series && labels_fit?(labels)

        count = 0
        labels.delete_if do |name, value|
          value = loki_value(value)
          next false if label_fits?(name, value) &&
                        (value.empty? || name == SERVICE_NAME || (count += 1) <= max_label_names_per_series)

          (@moved_labels ||= []) << [name, value]
        end
      end

      # Whether Loki accepts the length of each label's name and value (see #label_fits?).
      #
      # Every entry is checked, so an ASCII String, as most values are, is checked here, without
      # another method call.
      def labels_fit?(labels)
        max_name  = max_label_name_length
        max_value = max_label_value_length
        labels.each_pair do |name, value|
          next if value.is_a?(String) && value.ascii_only? && value.bytesize <= max_value && name.bytesize <= max_name
          return false unless label_fits?(name, value)
        end
        true
      end

      # Whether Loki accepts the length of the label's name and of its value, as Loki stores it, in
      # bytes, in UTF-8 without invalid bytes, as Utils.to_json writes them.
      #
      # The `level` Symbol and the `pid` Integer of every entry are read as text without asking
      # #loki_value, which first checks whether a value is a structure.
      def label_fits?(name, value)
        return false if name.bytesize > max_label_name_length

        text =
          case value
          when String then value
          when Symbol then value.name
          when Integer then value.to_s
          else loki_value(value)
          end
        text = Utils.encode_utf8_string(text) unless text.ascii_only?
        text.bytesize <= max_label_value_length
      end

      # Adds the labels past Loki's limits (see #limit_labels) to the structured metadata, after
      # the others, each under its name as Loki stores it, such as `a_b` for the label `a__b`
      # (see #loki_name), and with PAYLOAD_PREFIX when a payload key with that name would have it,
      # as for `duration` or `_` (see #prefixed_key?). When the structured metadata already has
      # that name, as Loki stores it, the label is written with a number after it, or not at all
      # when it has the same value (see #free_name).
      def moved_labels
        return unless @moved_labels

        names = payload_value.transform_keys { |name| loki_name(name.to_s) }
        @moved_labels.each do |name, value|
          name = prefixed_key?(name) ? prefixed_name(name) : loki_name(name)
          name = free_name(names, name, value, name.delete_suffix("_"))
          names[name] = payload_value[name] = value if name
        end
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
          exception_name:    (log.exception.class.name || log.exception.class).to_s,
          exception_message: Utils.exception_message(log.exception),
          stack_trace:       exception_backtrace
        )
      end

      # Returns [Hash] the payload as structured metadata, with String keys and values, since Loki
      # only accepts Strings.
      #
      # A key that Loki would store as one of this formatter's own names (see OWN_KEYS), or that it
      # would reject (see LETTER_OR_DIGIT), is written with PAYLOAD_PREFIX, after the other keys (see
      # #add_prefixed).
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
      # A key that is exactly one of OWN_KEYS is named first, so that `payload_metric_value` holds
      # the payload's `metric_value`, whatever the order of the keys, and `metric.value` is
      # prefixed again.
      def add_prefixed(metadata, prefixed)
        taken = Set.new(metadata.each_key) { |name| loki_name(name) }
        exact, lookalikes = prefixed.partition { |name, _value| OWN_KEYS.include?(name) }
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
      # name as: a name like one of OWN_KEYS starts with a letter, and one without a letter or
      # digit is stored as an empty name or as `_`, which Loki would write as one underscore with
      # the prefix's, so that underscore is left out.
      def prefixed_name(name)
        PAYLOAD_PREFIX + loki_name(name).delete_prefix("_")
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
      def loki_name(name)
        name = Utils.encode_utf8_string(name).gsub(LOKI_SEPARATOR, "_")
        name.match?(LEADING_DIGIT) ? "key_#{name}" : name
      end

      # Whether the payload key is written with PAYLOAD_PREFIX: Loki would store it as one of this
      # formatter's own names (see OWN_NAME), or it has no ASCII letter or digit (see
      # LETTER_OR_DIGIT).
      #
      # A name with characters outside ASCII is matched as Utils.to_json writes it: in UTF-8,
      # without invalid bytes, which matching it as it is could raise for. So a key of invalid
      # bytes alone is prefixed, since it is written as an empty name.
      def prefixed_key?(name)
        name = Utils.encode_utf8_string(name) unless name.ascii_only?
        name.match?(OWN_NAME) || !name.match?(LETTER_OR_DIGIT)
      end

      # Returns [String] the value as Loki accepts it.
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

      # Returns [Integer] the supplied limit (see #initialize).
      # Raises ArgumentError for any value other than an Integer of 0 or more, so that a mistake
      # surfaces here rather than on every log entry.
      def label_limit(option, value)
        return value if value.is_a?(Integer) && value >= 0

        raise(ArgumentError, "#{option} must be an Integer of 0 or more, not #{value.inspect}")
      end
    end
  end
end
