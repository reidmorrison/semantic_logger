require 'thread'
class Thread
  # Returns the name of the current thread
  # Default:
  #    JRuby: The Java thread name
  #    Other: String representation of this thread's object_id
  if defined? JRuby
    # Design Note:
    #   In JRuby with "thread.pool.enabled=true" each Ruby Thread instance is
    #   new, even though the Java threads are being re-used from the pool
    def name
      @name ||= JRuby.reference(self).native_thread.name
    end
  else
    def name
      @name ||= object_id.to_s
    end
  end

  # Set the name of this thread for logging and debugging purposes
  def name=(name)
    @name = name.to_s
  end
end