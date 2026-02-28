# frozen_string_literal: true

require_relative 'test_helper'

class TestPrivateIp < Minitest::Test
  def test_rfc1918_10
    assert PeekApi::SSRF.private_ip?('10.0.0.1')
    assert PeekApi::SSRF.private_ip?('10.255.255.255')
  end

  def test_rfc1918_172
    assert PeekApi::SSRF.private_ip?('172.16.0.1')
    assert PeekApi::SSRF.private_ip?('172.31.255.255')
  end

  def test_rfc1918_192
    assert PeekApi::SSRF.private_ip?('192.168.0.1')
    assert PeekApi::SSRF.private_ip?('192.168.255.255')
  end

  def test_cgnat
    assert PeekApi::SSRF.private_ip?('100.64.0.1')
    assert PeekApi::SSRF.private_ip?('100.127.255.255')
  end

  def test_loopback
    assert PeekApi::SSRF.private_ip?('127.0.0.1')
  end

  def test_zero
    assert PeekApi::SSRF.private_ip?('0.0.0.0')
  end

  def test_link_local
    assert PeekApi::SSRF.private_ip?('169.254.1.1')
  end

  def test_ipv6_loopback
    assert PeekApi::SSRF.private_ip?('::1')
  end

  def test_ipv6_link_local
    assert PeekApi::SSRF.private_ip?('fe80::1')
  end

  def test_ipv4_mapped_ipv6_private
    assert PeekApi::SSRF.private_ip?('::ffff:10.0.0.1')
    assert PeekApi::SSRF.private_ip?('::ffff:192.168.1.1')
  end

  def test_public_ip_allowed
    refute PeekApi::SSRF.private_ip?('8.8.8.8')
    refute PeekApi::SSRF.private_ip?('1.1.1.1')
    refute PeekApi::SSRF.private_ip?('203.0.113.1')
  end

  def test_hostname_returns_false
    refute PeekApi::SSRF.private_ip?('example.com')
  end
end

class TestValidateEndpoint < Minitest::Test
  def test_empty_raises
    assert_raises(ArgumentError) { PeekApi::SSRF.validate_endpoint!('') }
    assert_raises(ArgumentError) { PeekApi::SSRF.validate_endpoint!(nil) }
  end

  def test_https_required
    assert_raises(ArgumentError) { PeekApi::SSRF.validate_endpoint!('http://example.com/ingest') }
  end

  def test_http_allowed_for_localhost
    result = PeekApi::SSRF.validate_endpoint!('http://localhost:3000/ingest')
    assert_equal 'http://localhost:3000/ingest', result
  end

  def test_http_allowed_for_127
    result = PeekApi::SSRF.validate_endpoint!('http://127.0.0.1:3000/ingest')
    assert_equal 'http://127.0.0.1:3000/ingest', result
  end

  def test_blocks_private_ips
    assert_raises(ArgumentError) { PeekApi::SSRF.validate_endpoint!('https://10.0.0.1/ingest') }
    assert_raises(ArgumentError) { PeekApi::SSRF.validate_endpoint!('https://192.168.1.1/ingest') }
  end

  def test_blocks_credentials
    assert_raises(ArgumentError) { PeekApi::SSRF.validate_endpoint!('https://user:pass@example.com/ingest') }
  end

  def test_valid_https
    result = PeekApi::SSRF.validate_endpoint!('https://example.com/functions/v1/ingest')
    assert_equal 'https://example.com/functions/v1/ingest', result
  end

  def test_malformed_url
    assert_raises(ArgumentError) { PeekApi::SSRF.validate_endpoint!('not-a-url') }
  end
end
