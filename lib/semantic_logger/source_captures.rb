module SemanticLogger
  # The source captures of a list of appenders: the objects that keep, on each log entry, something
  # that only the thread that logged it can read, such as the current span or a client's scope, for
  # the appenders to use later on their own thread (see Subscriber#source_captures).
  #
  # It knows each distinct capture once, with the appenders that use it, so that a capture that
  # several appenders use runs once per entry, and runs it only for an entry that one of them writes,
  # by its level. The appender's filter is left to the appenders' thread, so that it runs once there.
  # Built from the appenders as they are, so it is never changed: Appenders builds another once they
  # change (see .changed).
  #
  # The application's own on_log subscribers run before, on the same thread (see Logger#log).
  class SourceCaptures
    # Counts the changes that can change the captures of the appenders: an appender added or removed,
    # or given another formatter. Only compared with the count that a plan was built at, so that a
    # change made by two threads at once, which may count once, is still seen. Trap-safe: no lock.
    @generation = 0

    # Shareable captures of the main processor's appenders, run in a Ractor other than the main one
    # (see .publish).
    @shareable = Utils.make_shareable([].freeze)

    class << self
      # Returns [Integer] the count of changes (see .changed).
      attr_reader :generation

      # Returns [Array<#call>] the shareable captures that a Ractor other than the main one runs for
      # each entry logged in it, those of the main processor's appenders when they last changed (see
      # .publish), without checking the appenders' levels, which only the main Ractor can read.
      attr_reader :shareable
    end

    # Records that the captures of some appender may have changed, such as when it was given another
    # formatter, so that the next log entry has the appenders build their captures again. Only the
    # main Ractor has the appenders, so a change in another Ractor, such as to the appender of its
    # internal logger, changes nothing.
    def self.changed
      @generation += 1 unless RactorSupport.other_ractor?
      nil
    end

    # Keeps the shareable captures of the plan, for the entries logged in a Ractor other than the main
    # one (see .shareable). Called in the main Ractor, for the main processor's appenders.
    def self.publish(plan)
      @shareable = Utils.make_shareable(plan.captures.select { |capture| ::Ractor.shareable?(capture) })
    end

    # Runs the shareable captures in a Ractor other than the main one, reporting any that raises to
    # the internal logger of the reporter, its processor.
    def self.call_shareable(log, reporter)
      shareable.each do |capture|
        capture.call(log)
      rescue Exception => e
        reporter.logger.error("Exception calling a source capture", e)
      end
    end

    NONE = [].freeze
    private_constant :NONE

    # Returns [Integer] the count of changes that this plan was built at (see .changed).
    attr_reader :generation

    # Parameters
    #   appenders: [Array<Subscriber|Appender::Async>]
    #     The appenders, each answering #source_captures and #writes_level?. One that does not, such as
    #     a stand-in for one, has none.
    #   generation: [Integer]
    #     The count of changes read before the appenders were, so that a change made meanwhile has the
    #     plan built again.
    def initialize(appenders, generation)
      @generation = generation
      owners      = {}
      appenders.each do |appender|
        next unless appender.respond_to?(:source_captures)

        Array(appender.source_captures).each { |capture| (owners[capture] ||= []) << appender }
      end
      @entries = owners.map { |capture, list| [capture, list.freeze].freeze }.freeze
    end

    # Returns [true|false] whether the plan was built at the current count of changes.
    def current?
      @generation == self.class.generation
    end

    # Returns [true|false] whether there is no capture to run.
    def empty?
      @entries.empty?
    end

    # Returns [Array<#call>] the captures, each once.
    def captures
      @entries.empty? ? NONE : @entries.map(&:first)
    end

    # Runs each capture that an appender using it writes the entry at its level, on the calling
    # thread. A capture that raises is reported to the internal logger of the reporter, such as the
    # appenders, and the others still run, as an on_log subscriber that raises is (see
    # Logger.call_subscribers).
    def call(log, reporter)
      @entries.each do |capture, owners|
        next unless owners.any? { |owner| owner.writes_level?(log) }

        capture.call(log)
      rescue Exception => e
        reporter.logger.error("Exception calling a source capture", e)
      end
      nil
    end
  end
end
