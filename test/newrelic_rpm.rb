# Mocked NewRelic::Agent used for testing

module NewRelic
  module Agent
    @@message = nil
    @@hash = nil

    def self.notice_error(message, hash)
      @@message = message
      @@hash = hash
    end

    def self.message
      @@message
    end

    def self.hash
      @@hash
    end
  end
end
