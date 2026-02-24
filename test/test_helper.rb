# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "webrick"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "apidash"

# Lightweight HTTP test server that records payloads.
class IngestServer
  attr_reader :payloads, :port

  def initialize(status: 200)
    @payloads = []
    @status = status
    @mutex = Mutex.new
    @server = nil
  end

  def start
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new("/dev/null"),
      AccessLog: []
    )
    @port = @server.config[:Port]

    handler = self
    @server.mount_proc("/ingest") do |req, res|
      body = req.body
      events = JSON.parse(body) if body && !body.empty?
      handler.record(events)
      res.status = handler.response_status
      res["Content-Type"] = "application/json"
      res.body = JSON.generate({ accepted: events&.size || 0 })
    end

    @thread = Thread.new { @server.start }
    sleep 0.1 # Wait for server to bind
    self
  end

  def stop
    @server&.shutdown
    @thread&.join(2)
  end

  def record(events)
    @mutex.synchronize { @payloads << events }
  end

  def response_status
    @status
  end

  def response_status=(status)
    @status = status
  end

  def endpoint
    "http://localhost:#{@port}/ingest"
  end

  def all_events
    @mutex.synchronize { @payloads.flatten }
  end
end

def tmp_storage_path
  File.join(Dir.tmpdir, "apidash-test-#{SecureRandom.hex(8)}.jsonl")
end
