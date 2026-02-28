# frozen_string_literal: true

require 'ipaddr'
require 'uri'

module PeekApi
  module SSRF
    # Private/reserved IPv4 networks
    PRIVATE_NETWORKS = [
      IPAddr.new('10.0.0.0/8'),
      IPAddr.new('172.16.0.0/12'),
      IPAddr.new('192.168.0.0/16'),
      IPAddr.new('100.64.0.0/10'),   # CGNAT
      IPAddr.new('127.0.0.0/8'),     # Loopback
      IPAddr.new('169.254.0.0/16'),  # Link-local
      IPAddr.new('0.0.0.0/8') # "This" network
    ].freeze

    # Private/reserved IPv6 networks
    PRIVATE_NETWORKS_V6 = [
      IPAddr.new('::1/128'),         # Loopback
      IPAddr.new('fe80::/10'),       # Link-local
      IPAddr.new('fc00::/7'),        # ULA
      IPAddr.new('::ffff:0:0/96') # IPv4-mapped (checked individually below)
    ].freeze

    module_function

    # Check if a hostname/IP is a private or reserved address.
    #
    # Covers: RFC 1918, CGNAT (100.64/10), loopback, link-local,
    # IPv6 ULA/link-local, IPv4-mapped IPv6.
    def private_ip?(host)
      addr = IPAddr.new(host)

      if addr.ipv6?
        # Check IPv4-mapped IPv6 (::ffff:x.x.x.x)
        if addr.ipv4_mapped?
          mapped = addr.native
          return PRIVATE_NETWORKS.any? { |net| net.include?(mapped) }
        end
        return PRIVATE_NETWORKS_V6.any? { |net| net.include?(addr) }
      end

      PRIVATE_NETWORKS.any? { |net| net.include?(addr) }
    rescue IPAddr::InvalidAddressError
      false
    end

    # Validate and normalize the ingestion endpoint URL.
    #
    # Raises ArgumentError for:
    #   - Non-HTTPS URLs (except localhost)
    #   - Private/reserved IP addresses (SSRF protection)
    #   - Embedded credentials in URL
    #   - Malformed URLs
    def validate_endpoint!(endpoint)
      raise ArgumentError, 'endpoint is required' if endpoint.nil? || endpoint.empty?

      uri = URI.parse(endpoint)
      raise ArgumentError, "Invalid endpoint URL: #{endpoint}" unless uri.is_a?(URI::HTTP) && uri.host

      hostname = uri.host.downcase

      is_localhost = %w[localhost 127.0.0.1 ::1].include?(hostname)

      unless uri.scheme == 'https' || is_localhost
        raise ArgumentError, "HTTPS required for non-localhost endpoint: #{endpoint}"
      end

      raise ArgumentError, 'Endpoint URL must not contain credentials' if uri.user || uri.password

      if !is_localhost && private_ip?(hostname)
        raise ArgumentError, "Endpoint resolves to private/reserved IP: #{hostname}"
      end

      endpoint
    rescue URI::InvalidURIError
      raise ArgumentError, "Invalid endpoint URL: #{endpoint}"
    end
  end
end
