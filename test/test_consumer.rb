# frozen_string_literal: true

require_relative "test_helper"

class TestHashConsumerId < Minitest::Test
  def test_format_prefix_and_length
    result = ApiDash::Consumer.hash_consumer_id("Bearer token123")
    assert result.start_with?("hash_"), "Expected hash_ prefix, got: #{result}"
    # hash_ (5 chars) + 12 hex chars = 17
    assert_equal 17, result.length
  end

  def test_deterministic
    a = ApiDash::Consumer.hash_consumer_id("same-value")
    b = ApiDash::Consumer.hash_consumer_id("same-value")
    assert_equal a, b
  end

  def test_different_inputs_produce_different_hashes
    a = ApiDash::Consumer.hash_consumer_id("value-a")
    b = ApiDash::Consumer.hash_consumer_id("value-b")
    refute_equal a, b
  end

  def test_hex_output
    result = ApiDash::Consumer.hash_consumer_id("test")
    hex_part = result.sub("hash_", "")
    assert_match(/\A[0-9a-f]{12}\z/, hex_part)
  end
end

class TestDefaultIdentifyConsumer < Minitest::Test
  def test_api_key_returned_as_is
    headers = { "x-api-key" => "ak_live_abc123" }
    assert_equal "ak_live_abc123", ApiDash::Consumer.default_identify_consumer(headers)
  end

  def test_api_key_priority_over_authorization
    headers = {
      "x-api-key" => "ak_live_abc123",
      "authorization" => "Bearer token",
    }
    assert_equal "ak_live_abc123", ApiDash::Consumer.default_identify_consumer(headers)
  end

  def test_authorization_hashed
    headers = { "authorization" => "Bearer secret-token" }
    result = ApiDash::Consumer.default_identify_consumer(headers)
    assert result.start_with?("hash_")
    assert_equal 17, result.length
  end

  def test_no_headers_returns_nil
    assert_nil ApiDash::Consumer.default_identify_consumer({})
  end

  def test_empty_api_key_falls_through
    headers = { "x-api-key" => "", "authorization" => "Bearer x" }
    result = ApiDash::Consumer.default_identify_consumer(headers)
    assert result.start_with?("hash_")
  end
end
