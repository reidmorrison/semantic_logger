module SemanticLogger
  # Where a log entry was logged: the path and line of the code that made the log call, and the
  # label of its frame, usually the method, such as "Order#submit".
  #
  # Log#assign sets it when the entry's level is at or above SemanticLogger.call_site_level. When the
  # log call supplies a backtrace, the call site is its first line. Otherwise it is the first frame of
  # the calling thread's stack outside Semantic Logger and SemanticLogger.call_site_skip_paths, which
  # costs far less than capturing a backtrace, since only the frames up to it are read.
  #
  # A call site is frozen and holds only frozen Strings and an Integer, so that a log entry logged in
  # another Ractor can be sent to the main one.
  #
  # Attributes:
  #   path: [String]
  #     The file, as in a backtrace, such as "/app/models/order.rb".
  #   line: [Integer]
  #     The line number in the file.
  #   label: [String|nil]
  #     The label of the frame, as in a backtrace. On Ruby 3.4 and later it includes the class, such
  #     as "Order#submit" or "Order.find_open", on Ruby 3.2 and 3.3 only the method, such as "submit".
  #     A block's label starts with "block in", and code outside a method has a label such as
  #     "<main>" or "<class:Order>".
  CallSite = Data.define(:path, :line, :label)

  class CallSite
    # The number of frames read from the stack at a time. Semantic Logger's own frames, which are
    # skipped, are usually fewer than this.
    WINDOW = 8
    private_constant :WINDOW

    # Paths of the frames of Ruby's own methods written in Ruby, such as Array#each and Kernel#tap on
    # Ruby 3.4 and later, which are never the code that logged the entry.
    INTERNAL_PATH = "<internal:".freeze
    private_constant :INTERNAL_PATH

    # A backtrace line that names its frame, such as "app.rb:12:in 'Order#submit'", or as Ruby 3.3
    # and earlier write it, "app.rb:12:in `submit'".
    LABELED_LINE = /\A(.*):(\d+):in [`'](.*)'\z/m
    private_constant :LABELED_LINE

    # A backtrace line without a label, such as "app.rb:12".
    UNLABELED_LINE = /\A(.*):(\d+)/
    private_constant :UNLABELED_LINE

    # Returns [CallSite|nil] where a log entry was logged: the first line of the backtrace that the log
    # call supplied, or without one, the first frame of the calling thread's stack outside Semantic
    # Logger (see .capture).
    def self.locate(supplied_backtrace = nil)
      supplied_backtrace ? parse(supplied_backtrace.first) : capture
    end

    # Returns [CallSite|nil] the first frame of the calling thread's stack outside Semantic Logger, Ruby's
    # own methods, and SemanticLogger.call_site_skip_paths. nil when every frame is skipped.
    def self.capture
      skip_paths = SemanticLogger.call_site_skip_paths
      # A Ractor other than the main one cannot use the main Ractor's cache.
      cache      = RactorSupport.other_ractor? ? nil : skip_cache(skip_paths)
      start      = 1
      # caller_locations returns nil, or on JRuby an empty Array, once start is past the end of the stack.
      while (locations = caller_locations(start, WINDOW)) && !locations.empty?
        locations.each do |location|
          path = location.path
          next if skip?(path, skip_paths, cache)

          label = location.label
          return new(-path, location.lineno, label && -label)
        end
        start += WINDOW
      end
    end

    # Returns [CallSite|nil] the call site in a line of a backtrace, such as
    # "app.rb:12:in 'Order#submit'". nil when the line is not a String with a path and line number.
    def self.parse(line)
      return unless line.is_a?(String)

      match = LABELED_LINE.match(line) || UNLABELED_LINE.match(line)
      return unless match

      label = match[3]
      new(-match[1], match[2].to_i, label && -label)
    end

    # Whether a frame in the file at this path is skipped when capturing a call site.
    #
    # The frames of log calls come from a few files, Semantic Logger's own and the application's, so
    # the answer is remembered in the cache for each path, which is faster than matching the path
    # again. Without a cache, the path is matched each time.
    def self.skip?(path, skip_paths, cache)
      return skip_path?(path, skip_paths) unless cache

      skipped = cache[path]
      return skipped unless skipped.nil?

      # Bounded, since code evaluated at runtime can have a path of its own each time.
      cache.clear if cache.size >= MAX_CACHED_PATHS
      cache[path] = skip_path?(path, skip_paths)
    end
    private_class_method :skip?

    # The most paths whose answer .skip? remembers.
    MAX_CACHED_PATHS = 1_000
    private_constant :MAX_CACHED_PATHS

    # Returns [Concurrent::Map] whether each path is skipped, for these skip paths. A new one when the
    # skip paths have changed.
    def self.skip_cache(skip_paths)
      cache = @skip_cache
      return cache.last if cache&.first.equal?(skip_paths)

      (@skip_cache = [skip_paths, Concurrent::Map.new]).last
    end
    private_class_method :skip_cache

    def self.skip_path?(path, skip_paths)
      return true if path.start_with?(INTERNAL_PATH) || Utils.extract_path?(path)

      skip_paths.any? { |skip_path| path.include?(skip_path) }
    end
    private_class_method :skip_path?

    # Returns [Array<String, Integer>] the file name and line number of the call site. With short_name
    # the file name has no directory, such as "order.rb".
    def file_name_and_line(short_name: false)
      [short_name ? File.basename(path) : path, line]
    end

    # Returns [String] the call site as Ruby 3.4 and later write it in a backtrace, such as
    # "/app/models/order.rb:42:in 'Order#submit'".
    def to_s
      label ? "#{path}:#{line}:in '#{label}'" : "#{path}:#{line}"
    end
  end
end
