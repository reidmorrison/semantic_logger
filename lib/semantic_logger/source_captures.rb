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
        report_failed_capture(reporter, e)
      end
    end

    # Reports a capture that raised to the internal logger of the reporter, without raising from the
    # log call when the internal logger fails too, such as on a closed stream.
    def self.report_failed_capture(reporter, exception)
      reporter.logger.error("Exception calling a source capture", exception)
    rescue StandardError
      nil
    end

    NONE = [].freeze
    private_constant :NONE

    # Returns [Integer] the count of changes that this plan was built at (see .changed).
    attr_reader :generation

    # Parameters
    #   appenders: [Array<Subscriber|Appender::Async>]
    #     The appenders, each answering #source_captures and #writes_level?. One that does not answer
    #     both, such as a stand-in for one, has none.
    #   generation: [Integer]
    #     The count of changes read before the appenders were, so that a change made meanwhile has the
    #     plan built again.
    #
    # An appender whose #source_captures raises has none, so that a log call never raises for it, and
    # is kept with its error (see #failures).
    def initialize(appenders, generation)
      @generation = generation
      @failures   = []
      # By identity, so that two captures that are equal, such as two Structs, each run.
      owners      = {}.compare_by_identity
      appenders.each do |appender|
        captures_of(appender).each { |capture| (owners[capture] ||= []) << appender }
      end
      @entries  = owners.map { |capture, list| [capture, list.freeze].freeze }.freeze
      @failures = @failures.freeze
    end

    # Returns [Array<Array(Object, Exception)>] each appender whose #source_captures raised, with its
    # error.
    attr_reader :failures

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
        self.class.report_failed_capture(reporter, e)
      end
      nil
    end

    private

    # Returns [Array<#call>] the captures of the appender, none when it does not answer both
    # #source_captures and #writes_level?, or when #source_captures raises, which is kept (see
    # #failures).
    def captures_of(appender)
      return NONE unless appender.respond_to?(:source_captures) && appender.respond_to?(:writes_level?)

      Array(appender.source_captures)
    rescue StandardError, ScriptError => e
      @failures << [appender, e]
      NONE
    end

    # The source captures of a list of appenders as they are now: it builds them from the appenders,
    # again after they or the captures of one of them changed (see SourceCaptures.changed), and runs
    # them for each log entry, on the thread that logged it.
    #
    # Held apart from the list, Appenders, which is a Concurrent::Array, whose every method JRuby
    # synchronizes, so that a log call never waits for the thread that writes to the appenders while
    # it holds the list. The list is read only to build the captures again.
    class Current
      # Parameters
      #   appenders: [Appenders]
      #     The appenders whose captures these are, which also answer the internal logger to report
      #     to (#logger).
      def initialize(appenders)
        @appenders = appenders
        @plan      = nil
        # The appenders whose #source_captures raised as the captures were last built, each reported
        # once. Replaced rather than changed, without a lock, since several threads can build the
        # captures at once, and in a signal trap: two of them may report the same one. Only those
        # still failing are kept, so that a removed appender is not held.
        @reported  = {}.compare_by_identity.freeze
      end

      # Runs the captures for the log entry, on the calling thread, which logged it, building them
      # again first when they changed.
      def capture(log)
        plan = @plan
        plan = rebuild unless plan&.current?
        plan.call(log, @appenders) unless plan.empty?
      end

      # Builds the captures of the appenders as they are now, reports each appender whose
      # #source_captures raised once, and publishes the shareable captures when these are the
      # appenders of the main processor. The count of changes is read before the appenders, so that
      # a change made meanwhile has them built again. Returns [SourceCaptures] them.
      def rebuild
        generation = SourceCaptures.generation
        plan       = SourceCaptures.new(@appenders.to_a, generation)
        report(plan.failures)
        @plan = plan
        SourceCaptures.publish(plan) if RactorSupport.enabled? && Logger.main_appenders?(@appenders)
        plan
      end

      private

      # Reports each appender whose #source_captures raised, unless it was already reported, without
      # raising from the log call that built the captures, even when the internal logger fails, such
      # as on a closed stream: each one is then still counted as reported.
      def report(failures)
        reported = @reported
        failing  = {}.compare_by_identity
        failures.each do |appender, exception|
          failing[appender] = true
          report_failure(appender, exception) unless reported.key?(appender)
        end
        @reported = failing.freeze
      end

      def report_failure(appender, exception)
        @appenders.logger.error("Exception asking an appender for its source captures: #{appender.class}", exception)
      rescue StandardError
        nil
      end
    end
  end
end
