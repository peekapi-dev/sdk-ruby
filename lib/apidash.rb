# frozen_string_literal: true

require_relative "apidash/version"
require_relative "apidash/consumer"
require_relative "apidash/ssrf"
require_relative "apidash/client"
require_relative "apidash/middleware/rack"

# Load Railtie only when Rails is present
require_relative "apidash/railtie" if defined?(Rails::Railtie)
