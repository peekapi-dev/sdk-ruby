# frozen_string_literal: true

require_relative 'peekapi/version'
require_relative 'peekapi/consumer'
require_relative 'peekapi/ssrf'
require_relative 'peekapi/client'
require_relative 'peekapi/middleware/rack'

# Load Railtie only when Rails is present
require_relative 'peekapi/railtie' if defined?(Rails::Railtie)
