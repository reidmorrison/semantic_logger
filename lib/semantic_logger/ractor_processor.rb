module SemanticLogger
  # Internal, experimental: the processor of a Ractor other than the main one. Ruby 4.0 and later
  # only.
  #
  # The appenders belong to the main Ractor, which only it can use, so this sends each log entry to
  # RactorReceiver in the main Ractor, which writes it to the appenders. It knows the name its Ractor
  # is logged as. Adding or changing appenders, like every other setting, is only possible in the main
  # Ractor.
  class RactorProcessor
    # Returns [RactorProcessor] the processor of the current Ractor.
    def self.current
      ::Ractor.store_if_absent(:semantic_logger_processor) { new }
    end

    # Returns [String] the name that identifies this Ractor in the thread name of its log entries: its
    # own name, or its number, as in "ractor-2".
    attr_reader :name

    def initialize
      ractor = ::Ractor.current
      @name  = ractor.name || "ractor-#{ractor.inspect[/\A#<Ractor:#(\d+)/, 1]}"
    end

    # Sends the log entry to the main Ractor. Its thread name is prefixed with this Ractor's name.
    #
    # Sending copies the entry. When something in it cannot be copied, such as a Proc in its payload,
    # those values are replaced (see Log#make_copyable) and it is sent again.
    def log(log)
      log.thread_name = "#{name}/#{log.thread_name}"
      begin
        RactorReceiver.port << [:log, *RactorCopy.pack(log)]
      rescue StandardError
        RactorReceiver.port << [:log, *RactorCopy.pack(log.make_copyable)]
      end
      true
    end

    # Waits until the main Ractor has written the entries sent before this call, and has flushed the
    # appenders. Returns the result of the main Ractor's flush, as SemanticLogger.flush there would.
    # Returns false without waiting when the main Ractor is not receiving, for example since no
    # appender was added.
    def flush
      return false unless RactorReceiver.running?

      reply = ::Ractor::Port.new
      RactorReceiver.port << [:flush, reply]
      reply.receive
    ensure
      reply&.close
    end

    # Returns the internal logger, to report problems logging in this Ractor, such as an on_log
    # subscriber that raised. It writes to this Ractor's $stderr.
    def logger
      @logger ||= Appender::IO.new($stderr, level: :warn).tap { |logger| logger.name = self.class.name }
    end

    # The operations that only the main Ractor can do, such as adding an appender.
    %i[appenders close reopen start queue queue_size stats lag_check_interval lag_threshold_s
       non_blocking?].each do |method|
      class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        def #{method}(*)                                 # def appenders(*)
          raise ::Ractor::IsolationError, main_only(:#{method}) #   raise ::Ractor::IsolationError, main_only(:appenders)
        end                                              # end
      RUBY
    end

    def lag_check_interval=(_value)
      raise ::Ractor::IsolationError, main_only(:lag_check_interval=)
    end

    def non_blocking=(_value)
      raise ::Ractor::IsolationError, main_only(:non_blocking=)
    end

    private

    def main_only(method)
      "Semantic Logger can only be configured in the main Ractor, not in #{name} (#{self.class.name}##{method})"
    end
  end
end
