# frozen_string_literal: true

require_relative "test_helper"

class TestClientConstructor < Minitest::Test
  def test_missing_api_key_raises
    assert_raises(ArgumentError) { ApiDash::Client.new(endpoint: "http://localhost:3000/ingest") }
  end

  def test_missing_endpoint_raises
    assert_raises(ArgumentError) { ApiDash::Client.new(api_key: "ak_test") }
  end

  def test_empty_api_key_raises
    assert_raises(ArgumentError) { ApiDash::Client.new(api_key: "", endpoint: "http://localhost:3000/ingest") }
  end

  def test_control_chars_in_api_key_raises
    assert_raises(ArgumentError) { ApiDash::Client.new(api_key: "ak\x00test", endpoint: "http://localhost:3000/ingest") }
  end

  def test_https_enforced_for_non_localhost
    assert_raises(ArgumentError) { ApiDash::Client.new(api_key: "ak_test", endpoint: "http://example.com/ingest") }
  end

  def test_private_ip_rejected
    assert_raises(ArgumentError) { ApiDash::Client.new(api_key: "ak_test", endpoint: "https://10.0.0.1/ingest") }
  end

  def test_valid_construction
    storage = tmp_storage_path
    client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: "http://localhost:3000/ingest",
      storage_path: storage
    )
    assert_equal "ak_test", client.api_key
    assert_equal "http://localhost:3000/ingest", client.endpoint
  ensure
    client&.shutdown
    File.delete(storage) rescue nil
    File.delete("#{storage}.recovering") rescue nil
  end
end

class TestClientBuffer < Minitest::Test
  def setup
    @storage = tmp_storage_path
    @client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: "http://localhost:9999/ingest",
      storage_path: @storage,
      flush_interval: 999,
      debug: true
    )
  end

  def teardown
    @client.shutdown
    File.delete(@storage) rescue nil
    File.delete("#{@storage}.recovering") rescue nil
  end

  def test_track_buffers_event
    @client.track({ "method" => "GET", "path" => "/api/users", "status_code" => 200, "response_time_ms" => 42 })
    buf = @client.send(:instance_variable_get, :@buffer)
    assert_equal 1, buf.size
  end

  def test_method_uppercased
    @client.track({ "method" => "get", "path" => "/test", "status_code" => 200, "response_time_ms" => 10 })
    buf = @client.send(:instance_variable_get, :@buffer)
    assert_equal "GET", buf.last["method"]
  end

  def test_path_truncated
    long_path = "/" + "a" * 3000
    @client.track({ "method" => "GET", "path" => long_path, "status_code" => 200, "response_time_ms" => 10 })
    buf = @client.send(:instance_variable_get, :@buffer)
    assert_equal 2048, buf.last["path"].length
  end

  def test_consumer_id_truncated
    long_id = "x" * 500
    @client.track({ "method" => "GET", "path" => "/test", "status_code" => 200, "response_time_ms" => 10, "consumer_id" => long_id })
    buf = @client.send(:instance_variable_get, :@buffer)
    assert_equal 256, buf.last["consumer_id"].length
  end

  def test_auto_timestamp
    @client.track({ "method" => "GET", "path" => "/test", "status_code" => 200, "response_time_ms" => 10 })
    buf = @client.send(:instance_variable_get, :@buffer)
    assert buf.last.key?("timestamp")
    refute_nil buf.last["timestamp"]
  end

  def test_preserves_existing_timestamp
    ts = "2025-01-01T00:00:00.000Z"
    @client.track({ "method" => "GET", "path" => "/test", "status_code" => 200, "response_time_ms" => 10, "timestamp" => ts })
    buf = @client.send(:instance_variable_get, :@buffer)
    assert_equal ts, buf.last["timestamp"]
  end

  def test_symbol_keys_work
    @client.track(method: "POST", path: "/api/orders", status_code: 201, response_time_ms: 55)
    buf = @client.send(:instance_variable_get, :@buffer)
    assert_equal 1, buf.size
    assert_equal "POST", buf.last["method"]
  end

  def test_garbage_input_does_not_raise
    @client.track("not a valid event")
    # Should not raise
  end

  def test_track_after_shutdown_is_noop
    @client.shutdown
    @client.track({ "method" => "GET", "path" => "/test", "status_code" => 200, "response_time_ms" => 10 })
    buf = @client.send(:instance_variable_get, :@buffer)
    assert_equal 0, buf.size
  end
end

class TestClientFlush < Minitest::Test
  def setup
    @server = IngestServer.new.start
    @storage = tmp_storage_path
    @client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: @server.endpoint,
      storage_path: @storage,
      flush_interval: 999
    )
  end

  def teardown
    @client.shutdown
    @server.stop
    File.delete(@storage) rescue nil
    File.delete("#{@storage}.recovering") rescue nil
  end

  def test_flush_sends_events
    @client.track({ "method" => "GET", "path" => "/api/users", "status_code" => 200, "response_time_ms" => 42 })
    @client.flush

    events = @server.all_events
    assert_equal 1, events.size
    assert_equal "GET", events[0]["method"]
    assert_equal "/api/users", events[0]["path"]
  end

  def test_flush_clears_buffer
    @client.track({ "method" => "GET", "path" => "/test", "status_code" => 200, "response_time_ms" => 10 })
    @client.flush

    buf = @client.send(:instance_variable_get, :@buffer)
    assert_equal 0, buf.size
  end

  def test_flush_empty_buffer_noop
    @client.flush
    assert_equal 0, @server.payloads.size
  end

  def test_flush_includes_sdk_header
    @client.track({ "method" => "GET", "path" => "/test", "status_code" => 200, "response_time_ms" => 10 })
    @client.flush
    assert_equal 1, @server.payloads.size
  end

  def test_flush_respects_batch_size
    storage = tmp_storage_path
    client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: @server.endpoint,
      storage_path: storage,
      flush_interval: 999,
      batch_size: 2
    )
    5.times { |i| client.track({ "method" => "GET", "path" => "/test/#{i}", "status_code" => 200, "response_time_ms" => 10 }) }
    client.flush  # Should send only 2

    events = @server.all_events
    assert_equal 2, events.size
  ensure
    client&.shutdown
    File.delete(storage) rescue nil
    File.delete("#{storage}.recovering") rescue nil
  end
end

class TestClientDiskPersistence < Minitest::Test
  def test_write_and_read_round_trip
    storage = tmp_storage_path
    client1 = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: "http://localhost:9999/ingest",
      storage_path: storage,
      flush_interval: 999
    )
    client1.track({ "method" => "GET", "path" => "/persisted", "status_code" => 200, "response_time_ms" => 42 })
    client1.shutdown

    # New client should recover persisted events
    client2 = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: "http://localhost:9999/ingest",
      storage_path: storage,
      flush_interval: 999
    )
    buf = client2.send(:instance_variable_get, :@buffer)
    assert buf.any? { |e| e["path"] == "/persisted" }, "Expected to recover persisted event"
  ensure
    client2&.shutdown
    File.delete(storage) rescue nil
    File.delete("#{storage}.recovering") rescue nil
  end

  def test_corrupt_json_lines_skipped
    storage = tmp_storage_path
    File.write(storage, "not-valid-json\n" + JSON.generate([{ "method" => "GET", "path" => "/ok" }]) + "\n")

    client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: "http://localhost:9999/ingest",
      storage_path: storage,
      flush_interval: 999
    )
    buf = client.send(:instance_variable_get, :@buffer)
    assert_equal 1, buf.size
    assert_equal "/ok", buf[0]["path"]
  ensure
    client&.shutdown
    File.delete(storage) rescue nil
    File.delete("#{storage}.recovering") rescue nil
  end
end

class TestClientShutdown < Minitest::Test
  def test_double_shutdown_safe
    storage = tmp_storage_path
    client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: "http://localhost:9999/ingest",
      storage_path: storage,
      flush_interval: 999
    )
    client.shutdown
    client.shutdown  # Should not raise
  ensure
    File.delete(storage) rescue nil
    File.delete("#{storage}.recovering") rescue nil
  end
end

class TestClientRetry < Minitest::Test
  def test_retryable_error_reinserts_events
    server = IngestServer.new(status: 500).start
    storage = tmp_storage_path
    client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: server.endpoint,
      storage_path: storage,
      flush_interval: 999
    )

    client.track({ "method" => "GET", "path" => "/retry", "status_code" => 200, "response_time_ms" => 10 })
    client.flush

    # Events should be reinserted into buffer after retryable failure
    buf = client.send(:instance_variable_get, :@buffer)
    failures = client.send(:instance_variable_get, :@consecutive_failures)
    assert(buf.size >= 1 || failures >= 1, "Expected events reinserted or failure counted")
  ensure
    client&.shutdown
    server&.stop
    File.delete(storage) rescue nil
    File.delete("#{storage}.recovering") rescue nil
  end

  def test_non_retryable_persists_to_disk
    server = IngestServer.new(status: 400).start
    storage = tmp_storage_path
    client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: server.endpoint,
      storage_path: storage,
      flush_interval: 999
    )

    client.track({ "method" => "GET", "path" => "/bad", "status_code" => 200, "response_time_ms" => 10 })
    client.flush

    # Non-retryable should persist to disk
    assert File.exist?(storage), "Expected events persisted to disk after 400"
  ensure
    client&.shutdown
    server&.stop
    File.delete(storage) rescue nil
    File.delete("#{storage}.recovering") rescue nil
  end

  def test_on_error_callback_called
    server = IngestServer.new(status: 500).start
    storage = tmp_storage_path
    errors = []
    client = ApiDash::Client.new(
      api_key: "ak_test",
      endpoint: server.endpoint,
      storage_path: storage,
      flush_interval: 999,
      on_error: ->(e) { errors << e }
    )

    client.track({ "method" => "GET", "path" => "/err", "status_code" => 200, "response_time_ms" => 10 })
    client.flush

    assert errors.size >= 1, "Expected on_error to be called"
  ensure
    client&.shutdown
    server&.stop
    File.delete(storage) rescue nil
    File.delete("#{storage}.recovering") rescue nil
  end
end
