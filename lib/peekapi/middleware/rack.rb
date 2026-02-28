# frozen_string_literal: true

module PeekApi
  module Middleware
    # Rack middleware that tracks HTTP request analytics.
    #
    # Usage (Sinatra):
    #
    #   client = PeekApi::Client.new(api_key: "...", endpoint: "...")
    #   use PeekApi::Middleware::Rack, client: client
    #
    # Usage (Rails):
    #
    #   config.middleware.use PeekApi::Middleware::Rack, client: client
    #
    class Rack
      def initialize(app, client: nil)
        @app = app
        @client = client
      end

      def call(env)
        return @app.call(env) if @client.nil?

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, headers, body = @app.call(env)

        begin
          elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

          # Measure response size
          response_size = 0
          if headers['content-length']
            response_size = headers['content-length'].to_i
          else
            begin
              body.each { |chunk| response_size += chunk.bytesize }
            rescue StandardError
              nil
            end
          end

          consumer_id = identify_consumer(env)
          path = env['PATH_INFO'] || '/'
          if @client.collect_query_string
            qs = env['QUERY_STRING'].to_s
            unless qs.empty?
              sorted = qs.split('&').sort.join('&')
              path = "#{path}?#{sorted}"
            end
          end

          @client.track(
            'method' => env['REQUEST_METHOD'] || 'GET',
            'path' => path,
            'status_code' => status.to_i,
            'response_time_ms' => elapsed_ms.round(2),
            'request_size' => request_size(env),
            'response_size' => response_size,
            'consumer_id' => consumer_id
          )
        rescue StandardError
          # Never crash the app
        end

        [status, headers, body]
      rescue StandardError => e
        # If the app raises, still try to track
        begin
          elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
          consumer_id = identify_consumer(env)
          path = env['PATH_INFO'] || '/'
          if @client.collect_query_string
            qs = env['QUERY_STRING'].to_s
            unless qs.empty?
              sorted = qs.split('&').sort.join('&')
              path = "#{path}?#{sorted}"
            end
          end

          @client.track(
            'method' => env['REQUEST_METHOD'] || 'GET',
            'path' => path,
            'status_code' => 500,
            'response_time_ms' => elapsed_ms.round(2),
            'request_size' => request_size(env),
            'response_size' => 0,
            'consumer_id' => consumer_id
          )
        rescue StandardError
          # Never crash
        end

        raise e
      end

      private

      def identify_consumer(env)
        headers = extract_headers(env)
        if @client.identify_consumer
          @client.identify_consumer.call(headers)
        else
          PeekApi::Consumer.default_identify_consumer(headers)
        end
      end

      def extract_headers(env)
        headers = {}
        env.each do |key, value|
          next unless key.start_with?('HTTP_')

          header_name = key[5..].downcase.tr('_', '-')
          headers[header_name] = value
        end
        headers
      end

      def request_size(env)
        env['CONTENT_LENGTH'].to_i
      rescue StandardError
        0
      end
    end
  end
end
