module SemanticLogger
  # Internal, experimental: whether this Ruby can log from Ractors other than the main one (Ruby 4.0
  # and later), and whether the code running now is in such a Ractor. The rest of Semantic Logger asks
  # this module rather than checking Ractor itself.
  module RactorSupport
    if defined?(::Ractor::Port)
      # Returns [true] since this Ruby can log from Ractors other than the main one.
      def self.enabled?
        true
      end

      # Returns [true|false] whether the current Ractor is one other than the main one.
      def self.other_ractor?
        !::Ractor.main?
      end
    else
      # Returns [false] since this Ruby cannot log from Ractors other than the main one.
      def self.enabled?
        false
      end

      # Returns [false] since every log call runs in the main Ractor.
      def self.other_ractor?
        false
      end
    end
  end
end
