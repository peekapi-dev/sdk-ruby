# frozen_string_literal: true

require_relative "test_helper"

# Minimal Rack app for testing
class TestApp
  def initialize(status: 200, body: "OK", headers: {})
    @status = status
    @body = body
    @headers = { "content-type" => "text/plain" }.merge(headers)
  end

  def call(_env)
    [@status, @headers, [@body]]
  end
end

class RaisingApp
  def call(_env)
    raise "boom"
  end
end

# Stub client that records tracked events
class StubClient
  attr_reader :events
  attr_accessor :identify_consumer, :collect_query_string

  def initialize
    @events = []
    @identify_consumer = nil
    @collect_query_string = false
  end

  def track(event)
    @events << event
  end

  def shutdown; end
end

class TestRackMiddleware < Minitest::Test
  def test_200_response_tracked
    stub_client = StubClient.new
    app = TestApp.new(status: 200, body: "Hello")
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/api/users")
    status, _headers, body = middleware.call(env)

    assert_equal 200, status
    assert_equal ["Hello"], body
    assert_equal 1, stub_client.events.size

    event = stub_client.events.first
    assert_equal "GET", event["method"]
    assert_equal "/api/users", event["path"]
    assert_equal 200, event["status_code"]
    assert event["response_time_ms"].is_a?(Numeric)
    assert event["response_time_ms"] >= 0
  end

  def test_500_response_tracked
    stub_client = StubClient.new
    app = TestApp.new(status: 500, body: "Error")
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("POST", "/api/orders")
    status, _headers, _body = middleware.call(env)

    assert_equal 500, status
    assert_equal 1, stub_client.events.size
    assert_equal 500, stub_client.events.first["status_code"]
  end

  def test_consumer_id_from_api_key
    stub_client = StubClient.new
    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/api/users", "HTTP_X_API_KEY" => "ak_live_abc")
    middleware.call(env)

    assert_equal "ak_live_abc", stub_client.events.first["consumer_id"]
  end

  def test_consumer_id_from_authorization
    stub_client = StubClient.new
    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/api/users", "HTTP_AUTHORIZATION" => "Bearer token123")
    middleware.call(env)

    consumer = stub_client.events.first["consumer_id"]
    assert consumer.start_with?("hash_")
    assert_equal 17, consumer.length
  end

  def test_custom_identify_consumer
    stub_client = StubClient.new
    stub_client.identify_consumer = ->(headers) { headers["x-tenant-id"] }

    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/api/users", "HTTP_X_TENANT_ID" => "tenant-42", "HTTP_X_API_KEY" => "ignored")
    middleware.call(env)

    assert_equal "tenant-42", stub_client.events.first["consumer_id"]
  end

  def test_no_client_passthrough
    app = TestApp.new(status: 200, body: "OK")
    middleware = PeekApi::Middleware::Rack.new(app, client: nil)

    env = rack_env("GET", "/test")
    status, _headers, body = middleware.call(env)

    assert_equal 200, status
    assert_equal ["OK"], body
  end

  def test_middleware_never_raises_on_tracking_error
    # Use a client that raises on track
    bad_client = Object.new
    def bad_client.track(_event)
      raise "tracking failed"
    end

    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: bad_client)

    env = rack_env("GET", "/test")
    status, _headers, body = middleware.call(env)

    # Should still return the response
    assert_equal 200, status
    assert_equal ["OK"], body
  end

  def test_app_exception_still_tracked
    stub_client = StubClient.new
    app = RaisingApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/fail")
    assert_raises(RuntimeError) { middleware.call(env) }

    assert_equal 1, stub_client.events.size
    assert_equal 500, stub_client.events.first["status_code"]
    assert_equal "/fail", stub_client.events.first["path"]
  end

  def test_request_size_captured
    stub_client = StubClient.new
    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("POST", "/api/data", "CONTENT_LENGTH" => "1024")
    middleware.call(env)

    assert_equal 1024, stub_client.events.first["request_size"]
  end

  def test_response_size_from_content_length
    stub_client = StubClient.new
    app = TestApp.new(status: 200, body: "Hello", headers: { "content-length" => "5" })
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/test")
    middleware.call(env)

    assert_equal 5, stub_client.events.first["response_size"]
  end

  def test_post_method_captured
    stub_client = StubClient.new
    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("POST", "/api/create")
    middleware.call(env)

    assert_equal "POST", stub_client.events.first["method"]
  end

  def test_collect_query_string_disabled_by_default
    stub_client = StubClient.new
    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/search", "QUERY_STRING" => "z=3&a=1")
    middleware.call(env)

    assert_equal "/search", stub_client.events.first["path"]
  end

  def test_collect_query_string_enabled
    stub_client = StubClient.new
    stub_client.collect_query_string = true
    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/search", "QUERY_STRING" => "z=3&a=1")
    middleware.call(env)

    assert_equal "/search?a=1&z=3", stub_client.events.first["path"]
  end

  def test_collect_query_string_sorts_params
    stub_client = StubClient.new
    stub_client.collect_query_string = true
    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/users", "QUERY_STRING" => "role=admin&name=alice")
    middleware.call(env)

    assert_equal "/users?name=alice&role=admin", stub_client.events.first["path"]
  end

  def test_collect_query_string_no_qs
    stub_client = StubClient.new
    stub_client.collect_query_string = true
    app = TestApp.new
    middleware = PeekApi::Middleware::Rack.new(app, client: stub_client)

    env = rack_env("GET", "/users")
    middleware.call(env)

    assert_equal "/users", stub_client.events.first["path"]
  end

  private

  def rack_env(method, path, extra = {})
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "rack.input" => StringIO.new(""),
    }.merge(extra)
  end
end
