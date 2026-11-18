module SemanticLogger
  module Formatters
    class Loki < Base
      # The labels of the stream of one log entry, as Loki accepts them: Loki rejects the whole
      # push, with every entry in it, for a label name it does not accept, or past one of its
      # limits, and keeps only one value of a label name.
      #
      # It knows the labels written so far, a Hash of their names, as Strings, and their values, to
      # which the formatter has written its own labels first (see Loki#build_stream), whether a
      # name may still be a Symbol, the labels still to be written under another name, Loki's
      # limits, and how many labels there were when it finished them. It writes each name as a
      # String (see #string_names), adds the named tags and the context to the labels (see #add),
      # and then writes those that need another name and takes out those past Loki's limits (see
      # #finish), which the formatter writes to the structured metadata instead. It names them by
      # the formatter's rules (see Loki.loki_name and Loki.free_name), and converts their values
      # with the converter the formatter gives it.
      class Labels
        # Matches a label name that Loki accepts: an ASCII letter or an underscore, followed by
        # ASCII letters, digits, and underscores. Loki rejects the whole push for any other, such
        # as `request-id`, `1st`, or an empty name, with "couldn't parse labels".
        LABEL_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

        # The name of a label whose key is empty, with the prefix that Loki puts before a name that
        # starts with a digit.
        EMPTY_LABEL_NAME = "key_".freeze

        # The label that Loki adds to a stream that does not have it, and does not count toward
        # max_label_names_per_series, even when the stream has it.
        SERVICE_NAME = "service_name".freeze

        # Parameters
        #   labels: [Hash]
        #     The labels written so far, which this adds to, and takes the labels past Loki's
        #     limits from.
        #   loki_value: [#call]
        #     Returns a value as Loki stores it, a String: the formatter's #loki_value, which a
        #     subclass of the formatter may override.
        #   max_names, max_name_length, max_value_length: [Integer]
        #     Loki's limits, see Loki#initialize.
        #   symbols: [true|false]
        #     Whether a label may have a name that is not a String, such as a Symbol that a
        #     subclass of the formatter written for v5.2 writes its own label under, as v5.2 did.
        #     The names are then written as Strings (see #string_names) before the first label is
        #     added, and as the labels are finished.
        #     Default: false, as the formatter's own methods write every label under a String.
        def initialize(labels, loki_value, max_names, max_name_length, max_value_length, symbols: false)
          @labels           = labels
          @loki_value       = loki_value
          @max_names        = max_names
          @max_name_length  = max_name_length
          @max_value_length = max_value_length
          @symbols          = symbols
          @unchecked        = symbols
          @renamed          = nil
          @finished_size    = nil
        end

        # Whether these are the labels of the supplied Hash: the same Hash, not an equal one.
        def of?(labels)
          @labels.equal?(labels)
        end

        # Whether #finish has written and limited these labels, and no label was added since, as a
        # subclass of the formatter may add one after its #build_stream called super, even under
        # the name of another label, such as `:level` beside `"level"`. A label whose value was
        # replaced since is not seen.
        def finished?
          @finished_size == @labels.size
        end

        # Adds the label of a named tag or a value of the context, with its value as Loki stores it
        # (see #initialize), unless the value is nil, which Loki would store as the text "null".
        #
        # Loki rejects the whole push for a label name it does not accept (see LABEL_NAME), so such
        # a name is replaced (see #label_name_for). Loki keeps one value of a label name, so a label
        # whose name another label already has is written once when that label has the same value,
        # as Loki stores it, and otherwise under another name. Both are written after the others,
        # by #finish, so that the name they get is not one that a later label has as its own.
        def add(key, value)
          return if value.nil?

          string_names if @unchecked
          name  = key.is_a?(Symbol) ? key.name : key.to_s
          value = @loki_value.call(value)
          if !label_name?(name)
            (@renamed ||= []) << [label_name_for(name), value]
          elsif !@labels.key?(name)
            @labels[name] = value
          else
            (@renamed ||= []) << [name, value]
          end
        end

        # Writes the labels whose names are taken or were replaced (see #add), after the others, so
        # that a label written under its own name keeps it (see #write_renamed), and then takes out
        # the labels past Loki's limits (see #limit). A label written under a Symbol since, as by a
        # subclass of the formatter, is first written under a String (see #string_names).
        #
        # It can finish them again, after more labels were added (see #finished?).
        #
        # Returns [Array<Array(String, String)>|nil] the labels taken out, each its name and its
        # value as Loki stores it, or nil when there are none.
        def finish
          string_names if @symbols
          write_renamed if @renamed
          moved          = limit
          @finished_size = @labels.size
          moved
        end

        private

        # Writes each label whose name is not a String under its name as a String, in place and in
        # the same order, such as the `:host` of a subclass's own #host, or the `{pid: pid}` of
        # v5.2's #build_stream. Otherwise #add would not find its name among the labels, and would
        # write a named tag of that name beside it, so the JSON would have the name twice, which
        # json 3 refuses to write. When a label written before it has that name, it is written
        # after the others, as a named tag whose name is taken is (see #write_renamed), with a
        # number unless it has the same value. So #add, #write_renamed, #limit, and #fit? find
        # every label by its name as a String.
        #
        # It runs before the first named tag or context key is added, so that the labels are
        # numbered in the order they are written in, and again as they are finished, for a label
        # written since. Nearly every stream has String names alone, which Hash#any? checks without
        # allocating.
        def string_names
          @unchecked = false
          return unless @labels.any? { |name, _value| !name.is_a?(String) }

          written = @labels.to_a
          @labels.clear
          written.each do |name, value|
            name = name.is_a?(Symbol) ? name.name : name.to_s
            if @labels.key?(name)
              (@renamed ||= []) << [name, @loki_value.call(value)]
            else
              @labels[name] = value
            end
          end
        end

        # Writes the labels whose names are taken or were replaced (see #add) in two passes: first
        # each whose name is free, and then each of the rest, under the name that Loki.free_name
        # gives it, or not at all when the label of that name, or of a numbered name before it, has
        # the same value (see #same_value?). So the number a label gets is never the name that
        # another of them is written under, such as `host_2` for a named tag `host-2`, whatever the
        # order of their keys. Only Loki.free_name compares the values, so that the value of each
        # label a label is compared with is converted once.
        def write_renamed
          pending = @renamed.reject do |name, value|
            next false if @labels.key?(name)

            @labels[name] = value
            true
          end
          @renamed = nil
          pending.each do |name, value|
            name = Loki.free_name(@labels, name) { |held| same_value?(held, value) }
            @labels[name] = value if name
          end
        end

        # Whether a label's value, as Loki stores it, is the supplied value. A value that is not a
        # String, such as the `level` Symbol or the `pid` Integer of the formatter's own labels, is
        # compared as Loki stores it.
        def same_value?(held, value)
          @loki_value.call(held) == value
        end

        # Whether Loki accepts the name as a label name. A name with characters outside ASCII never
        # is, and matching it could raise, when it holds invalid UTF-8.
        def label_name?(name)
          name.ascii_only? && name.match?(LABEL_NAME)
        end

        # Returns [String] a name that Loki accepts for a label whose name it does not: the name
        # under which Loki stores structured metadata of that name (see Loki.loki_name), such as
        # `request_id` for `request-id`, and `key_1st` for `1st`, or EMPTY_LABEL_NAME for an empty
        # name.
        def label_name_for(name)
          name = Loki.loki_name(name)
          name.empty? ? EMPTY_LABEL_NAME : name
        end

        # Takes out each label for which Loki would reject the whole push, with every entry in it,
        # so that the push is accepted, and the value is kept in the structured metadata: a label
        # whose name is longer than max_name_length, or whose value, as Loki stores it, is longer
        # than max_value_length, and each label past max_names, in the order they are written (see
        # Loki#build_stream).
        #
        # As Loki 3.7.10 does, a label with an empty value, which Loki leaves out, is neither
        # checked nor counted, and SERVICE_NAME is not counted.
        #
        # Returns [Array<Array(String, String)>|nil] the labels taken out, each its name as a String
        # and its value as Loki stores it, or nil when there are none.
        def limit
          return if @labels.size <= @max_names && fit?

          moved = nil
          count = 0
          @labels.delete_if do |name, value|
            next false if empty_value?(value) ||
                          (label_fits?(name, value) && (name == SERVICE_NAME || (count += 1) <= @max_names))

            (moved ||= []) << [name, @loki_value.call(value)]
          end
          moved
        end

        # Whether Loki accepts the length of each label's name and value (see #label_fits?). A
        # label with an empty value fits, whatever the length of its name, since Loki leaves it out.
        #
        # Every entry is checked, so an ASCII String, as most values are, is checked here, without
        # another method call.
        def fit?
          max_name  = @max_name_length
          max_value = @max_value_length
          @labels.each_pair do |name, value|
            next if value.is_a?(String) && value.ascii_only? && value.bytesize <= max_value &&
                    (name.bytesize <= max_name || value.empty?)
            return false unless label_fits?(name, value) || empty_value?(value)
          end
          true
        end

        # Whether the value is empty, which Loki leaves out. A value that is neither a String nor a
        # Symbol, such as the `pid` Integer or the tags, is never written as an empty value.
        def empty_value?(value)
          (value.is_a?(String) || value.is_a?(Symbol)) && value.empty?
        end

        # Whether Loki accepts the length of the label's name, a String, and of its value, as Loki
        # stores it, in bytes, in UTF-8 without invalid bytes, as Utils.to_json writes them.
        #
        # The `level` Symbol and the `pid` Integer of every entry are read as text without
        # converting them, which first checks whether a value is a structure, and the tags of
        # nearly every entry that has them are not written as JSON only to measure them (see
        # #short_strings?).
        def label_fits?(name, value)
          return false if name.bytesize > @max_name_length
          return true if short_strings?(value)

          text =
            case value
            when String then value
            when Symbol then value.name
            when Integer then value.to_s
            else @loki_value.call(value)
            end
          text = Utils.encode_utf8_string(text) unless text.ascii_only?
          text.bytesize <= @max_value_length
        end

        # Whether the value is an Array of Strings, such as the tags, whose JSON cannot be longer
        # than max_value_length: JSON writes each byte of a String as at most 6 bytes, as for a
        # control character, such as `\u0001`, with 2 quotes around it and a comma after it, all
        # within brackets.
        def short_strings?(value)
          return false unless value.is_a?(Array)

          size = 2
          value.each do |item|
            return false unless item.is_a?(String)

            size += (item.bytesize * 6) + 3
          end
          size <= @max_value_length
        end
      end
    end
  end
end
