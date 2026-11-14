module SemanticLogger
  # The logging context of a fiber: its tags, named tags, and silence level.
  #
  # An instance is a frozen snapshot of a fiber's context, returned by SemanticLogger.context, for
  # SemanticLogger.with_context to apply in another thread or fiber. It has `tags` (an Array),
  # `named_tags` (a Hash), and `silence` (the level Symbol set by SemanticLogger.silence, or nil).
  #
  # The class methods are internal. They manage the context of the current fiber, together with the
  # `with_level` overrides of its loggers, which are not part of a snapshot: like Ruby's
  # Logger#with_level they apply only to the fiber that set them. Only this class knows where that
  # state is kept: in fiber-local variables (`Thread.current[]`), so that every fiber, including the
  # fibers of a fiber scheduler such as Async, has its own.
  #
  # The stored lists are never changed in place. Each change stores a new frozen list, and the block
  # forms restore the previous list when the block exits. Code that copies fiber-local variables into
  # another thread, such as Rails' ActionController::Live, therefore hands over lists that Semantic
  # Logger never changes for the other thread. The tags in them are the caller's own objects.
  Context = Data.define(:tags, :named_tags, :silence)

  class Context
    TAGS_KEY       = :semantic_logger_tags
    NAMED_TAGS_KEY = :semantic_logger_named_tags
    SILENCE_KEY    = :semantic_logger_silence
    WITH_LEVEL_KEY = :semantic_logger_with_level
    EMPTY          = [].freeze
    EMPTY_HASH     = {}.freeze
    private_constant :TAGS_KEY, :NAMED_TAGS_KEY, :SILENCE_KEY, :WITH_LEVEL_KEY, :EMPTY, :EMPTY_HASH

    # Parameters
    #   tags: [Array]
    #     Positional tags.
    #   named_tags: [Hash]
    #     Named tags.
    #   silence: [Symbol|String|Integer]
    #     A level accepted by SemanticLogger.silence, or nil for none.
    def initialize(tags: EMPTY, named_tags: EMPTY_HASH, silence: nil)
      raise(ArgumentError, "tags must be an Array") unless tags.is_a?(Array)
      raise(ArgumentError, "named_tags must be a Hash") unless named_tags.is_a?(Hash)

      super(
        tags:       tags.frozen? ? tags : tags.dup.freeze,
        named_tags: named_tags.frozen? ? named_tags : named_tags.dup.freeze,
        silence:    silence.nil? ? nil : Levels.level(Levels.index(silence))
      )
    end

    # Returns [Context] a copy with the supplied members changed, checked and frozen as by .new,
    # which Data#with does not call on Ruby 3.2.
    def with(**changes)
      changes.empty? ? self : self.class.new(**to_h, **changes)
    end

    # A context with no tags, named tags, or silence level.
    NONE = new
    private_constant :NONE

    class << self
      # Returns [Context] a frozen snapshot of the current fiber's context.
      def current
        tags  = Thread.current[TAGS_KEY]
        named = Thread.current[NAMED_TAGS_KEY]
        index = Thread.current[SILENCE_KEY]
        return NONE if (tags.nil? || tags.empty?) && (named.nil? || named.empty?) && index.nil?

        new(tags: tags || EMPTY, named_tags: merge(named).freeze, silence: index && Levels.level(index))
      end

      # Runs the block with the supplied context as the current fiber's context, in place of the
      # fiber's own tags, named tags, and silence level, which are restored when the block exits.
      def use(context)
        raise(ArgumentError, "Expected a SemanticLogger::Context, got #{context.class}") unless context.is_a?(Context)

        previous = [Thread.current[TAGS_KEY], Thread.current[NAMED_TAGS_KEY], Thread.current[SILENCE_KEY]]
        begin
          Thread.current[TAGS_KEY]       = context.tags.empty? ? nil : context.tags
          Thread.current[NAMED_TAGS_KEY] = context.named_tags.empty? ? nil : [context.named_tags].freeze
          Thread.current[SILENCE_KEY]    = context.silence && Levels.index(context.silence)
          yield
        ensure
          Thread.current[TAGS_KEY], Thread.current[NAMED_TAGS_KEY], Thread.current[SILENCE_KEY] = previous
        end
      end

      # Returns [Array] a new Array of the tags of the thread's current fiber.
      def tags(thread = Thread.current)
        tags = thread[TAGS_KEY]
        tags ? tags.dup : []
      end

      # Returns [Hash] a new Hash of the named tags of the thread's current fiber.
      #
      # Each named tags block pushes its Hash onto a list; a later Hash wins on a key that is in both.
      def named_tags(thread = Thread.current)
        merge(thread[NAMED_TAGS_KEY])
      end

      # Runs the block with the tag added to the current fiber's tags.
      #
      # Like every block form below, it restores the previous value when the block exits, whatever
      # the block did to it. Each is written out in full, since this is on the hot path. Each reads
      # the previous value before its `begin`, so that an exception raised into the thread, such as
      # by Timeout, can never restore a value that was not read yet.
      def fast_tag(tag)
        previous = Thread.current[TAGS_KEY]
        begin
          Thread.current[TAGS_KEY] = (previous ? previous.dup << tag : [tag]).freeze
          yield
        ensure
          Thread.current[TAGS_KEY] = previous
        end
      end

      # Runs the block with the Array of tags added to the current fiber's tags. Takes ownership of
      # the Array, which it may freeze, so the caller must not keep it.
      def tagged(tags)
        previous = Thread.current[TAGS_KEY]
        begin
          Thread.current[TAGS_KEY] = (previous ? previous + tags : tags).freeze
          yield
        ensure
          Thread.current[TAGS_KEY] = previous
        end
      end

      # Adds the Array of tags to the current fiber's tags, until they are popped.
      def push_tags(tags)
        Thread.current[TAGS_KEY] = (current_tags + tags).freeze
      end

      # Removes the last `quantity` tags from the current fiber's tags.
      # Returns [Array] the tags removed, or nil when the fiber has no tags.
      def pop_tags(quantity)
        pop(TAGS_KEY, quantity)
      end

      # Runs the block with the Hash of named tags added to the current fiber's named tags.
      def named_tagged(hash)
        previous = Thread.current[NAMED_TAGS_KEY]
        begin
          Thread.current[NAMED_TAGS_KEY] = (previous ? previous.dup << hash : [hash]).freeze
          yield
        ensure
          Thread.current[NAMED_TAGS_KEY] = previous
        end
      end

      # Adds the Hash of named tags to the current fiber's named tags, until it is popped.
      def push_named_tags(hash)
        Thread.current[NAMED_TAGS_KEY] = (current_named_tags.dup << hash).freeze
      end

      # Removes the last `quantity` Hashes of named tags pushed onto the current fiber.
      # Returns [Array] the Hashes removed, or nil when the fiber has no named tags.
      def pop_named_tags(quantity)
        pop(NAMED_TAGS_KEY, quantity)
      end

      # Returns [Integer|nil] the level index set by an enclosing `silence` block on the current
      # fiber, or nil when there is none.
      def silence_index
        Thread.current[SILENCE_KEY]
      end

      # Runs the block with the supplied level index as the current fiber's silence level.
      def silence(index)
        previous = Thread.current[SILENCE_KEY]
        begin
          Thread.current[SILENCE_KEY] = index
          yield
        ensure
          Thread.current[SILENCE_KEY] = previous
        end
      end

      # Returns [Integer|nil] the level index set for the logger by an enclosing `with_level` block
      # on the current fiber, or nil when there is none.
      def with_level_index(logger)
        Thread.current[WITH_LEVEL_KEY]&.[](logger)
      end

      # Runs the block with the supplied level index for the logger on the current fiber.
      def with_level(logger, index)
        previous = Thread.current[WITH_LEVEL_KEY]
        begin
          overrides                      = previous ? previous.dup : {}.compare_by_identity
          overrides[logger]              = index
          Thread.current[WITH_LEVEL_KEY] = overrides.freeze
          yield
        ensure
          Thread.current[WITH_LEVEL_KEY] = previous
        end
      end

      private

      # Returns [Hash] a new Hash of the list of named tags Hashes merged, a later one winning.
      def merge(list)
        return {} if list.nil? || list.empty?

        list.size == 1 ? list.first.dup : list.reduce({}) { |sum, hash| sum.merge(hash) }
      end

      def current_tags
        Thread.current[TAGS_KEY] || EMPTY
      end

      def current_named_tags
        Thread.current[NAMED_TAGS_KEY] || EMPTY
      end

      # Pops from a copy of the list under the key, as Array#pop does, and stores the copy.
      def pop(key, quantity)
        list = Thread.current[key]&.dup
        return if list.nil?

        popped              = list.pop(quantity)
        Thread.current[key] = list.freeze
        popped
      end
    end
  end
end
