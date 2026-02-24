# frozen_string_literal: true

require_relative "lib/apidash/version"

Gem::Specification.new do |spec|
  spec.name = "apidash"
  spec.version = ApiDash::VERSION
  spec.authors = ["API Usage Dashboard"]
  spec.license = "MIT"

  spec.summary = "Zero-dependency Ruby SDK for API Usage Dashboard"
  spec.description = "Rack middleware and client for tracking API usage analytics. " \
                     "Works with Rails, Sinatra, Hanami, and any Rack-compatible framework."
  spec.homepage = "https://github.com/api-usage-dashboard/sdk-ruby"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "webrick", "~> 1.8"
end
