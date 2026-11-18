# Loaded now rather than autoloaded, since .logger builds one on first use, which can be the first log
# call of the process, made in a signal trap, where Ruby does not allow a require.
require "semantic_logger/appender/io"

module SemanticLogger
  # Thread that submits and processes log requests
  class Processor < Appender::Async
    # Allow the internal logger to be overridden from its default of $stderr
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders (raises ArgumentError)
    #
    # A Ruby or Rails logger is wrapped in an appender (see Appender.internal_logger), so .logger
    # returns that appender. The appenders added from then on report to it.
    def self.logger=(logger)
      @logger = Appender.internal_logger(logger)
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to $stderr
    def self.logger
      @logger ||=
        begin
          l      = SemanticLogger::Appender::IO.new($stderr, level: :warn)
          l.name = name
          l
        end
    end

    attr_reader :appenders

    def initialize(max_queue_size: 10_000)
      @appenders = Appenders.new(self.class.logger.dup)
      super(appender: @appenders, max_queue_size: max_queue_size)
    end

    # Reopen the appenders, after a fork or within the same process, each on the thread that writes
    # to it, between writes (see Appender::Async#reopen): the worker thread of this processor reopens
    # the appenders (see Appenders#reopen).
    #
    # After a fork, the queue and worker thread of each appender added with async: true or in batches
    # are first replaced on the calling thread, rather than once this processor's worker thread gets
    # to the reopen, so that they are running when this returns, such as for SemanticLogger.stats.
    # That worker thread still asks each of them to reopen its appender, ahead of the entries it
    # hands them. Takes no lock, so that it can be called from a signal trap.
    def reopen
      appenders.renew_after_fork
      super
    end

    # Returns [false]: another thread never waits for the calling thread to return from a call to this
    # processor before it can use it, since it holds no lock while it queues an entry.
    def current_thread_inside?
      false
    end

    # Start the appender thread
    def start
      return false if active?

      thread
      true
    end

    # Returns [Hash] operational statistics for the logging pipeline.
    #
    #   queue_size:     [Integer] Number of log messages waiting on the main pipeline queue.
    #   capped:         [Boolean] Whether the main queue has a maximum size.
    #   max_queue_size: [Integer] Maximum queue size, or nil when uncapped.
    #   thread_active:  [Boolean] Whether the main pipeline thread is running.
    #   processed:      [Integer] Cumulative number of log messages processed since startup.
    #   dropped:        [Integer] Cumulative number of log messages dropped at the main queue.
    #   appenders:      [Array<Hash>] Per-appender statistics, see Appenders#stats.
    def stats
      {
        queue_size:     queue.size,
        capped:         capped?,
        max_queue_size: capped? ? max_queue_size : nil,
        thread_active:  active? || false,
        processed:      processed_count,
        dropped:        dropped_count,
        appenders:      appenders.stats
      }
    end
  end
end
