module SemanticLogger
  # Custom logger that maps all calls to debug to trace calls
  # This is useful for existing gems / libraries that log too much to debug
  # when most of the debug logging should be at the trace level
  class MapDebugToTraceLogger < Logger
    def debug(*args, &block)
      trace(*args, &block)
    end

    def debug?
      trace?
    end

    def benchmark_debug(*args, &block)
      benchmark_trace(*args, &block)
    end
  end
end