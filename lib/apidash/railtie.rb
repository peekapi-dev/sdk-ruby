# frozen_string_literal: true

module ApiDash
  class Railtie < Rails::Railtie
    initializer "apidash.configure_middleware" do |app|
      api_key = ENV["APIDASH_API_KEY"]
      endpoint = ENV["APIDASH_ENDPOINT"]

      if api_key && !api_key.empty? && endpoint && !endpoint.empty?
        client = ApiDash::Client.new(api_key: api_key, endpoint: endpoint)
        app.middleware.use ApiDash::Middleware::Rack, client: client

        at_exit { client.shutdown }
      end
    end
  end
end
