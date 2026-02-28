# frozen_string_literal: true

module PeekApi
  class Railtie < Rails::Railtie
    initializer 'peekapi.configure_middleware' do |app|
      api_key = ENV.fetch('PEEKAPI_API_KEY', nil)
      endpoint = ENV.fetch('PEEKAPI_ENDPOINT', nil)

      if api_key && !api_key.empty? && endpoint && !endpoint.empty?
        client = PeekApi::Client.new(api_key: api_key, endpoint: endpoint)
        app.middleware.use PeekApi::Middleware::Rack, client: client

        at_exit { client.shutdown }
      end
    end
  end
end
