# frozen_string_literal: true

require "digest/sha2"

module ApiDash
  module Consumer
    module_function

    # SHA-256 hash truncated to 12 hex chars, prefixed with "hash_".
    def hash_consumer_id(raw)
      digest = Digest::SHA256.hexdigest(raw)[0, 12]
      "hash_#{digest}"
    end

    # Identify consumer from request headers.
    #
    # Priority:
    #   1. x-api-key (stored as-is)
    #   2. Authorization (hashed — contains credentials)
    #
    # Headers keys are expected to be lowercase (Rack convention).
    def default_identify_consumer(headers)
      api_key = headers["x-api-key"]
      return api_key if api_key && !api_key.empty?

      auth = headers["authorization"]
      return hash_consumer_id(auth) if auth && !auth.empty?

      nil
    end
  end
end
