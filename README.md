# PeekAPI — Ruby SDK

[![Gem](https://img.shields.io/gem/v/peekapi)](https://rubygems.org/gems/peekapi)
[![license](https://img.shields.io/gem/l/peekapi)](./LICENSE)
[![CI](https://github.com/peekapi-dev/sdk-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/peekapi-dev/sdk-ruby/actions/workflows/ci.yml)

Zero-dependency Ruby SDK for [PeekAPI](https://peekapi.dev). Rack middleware that works with Rails, Sinatra, Hanami, and any Rack-compatible framework. Rails auto-integrates via Railtie.

## Install

```bash
gem install peekapi
```

Or add to your Gemfile:

```ruby
gem "peekapi"
```

## Quick Start

### Rails (auto-integration)

Set environment variables and the Railtie handles everything:

```bash
export PEEKAPI_API_KEY=ak_live_xxx
export PEEKAPI_ENDPOINT=https://...
```

The SDK auto-inserts Rack middleware and registers a shutdown hook. No code changes needed.

### Rails (manual)

```ruby
# config/application.rb
client = PeekApi::Client.new(api_key: "ak_live_xxx")
config.middleware.use PeekApi::Middleware::Rack, client: client
```

### Sinatra

```ruby
require "sinatra"
require "peekapi"

client = PeekApi::Client.new(api_key: "ak_live_xxx")
use PeekApi::Middleware::Rack, client: client

get "/api/hello" do
  json message: "hello"
end
```

### Hanami

```ruby
# config/app.rb
require "peekapi"

client = PeekApi::Client.new(api_key: "ak_live_xxx")
middleware.use PeekApi::Middleware::Rack, client: client
```

### Standalone Client

```ruby
require "peekapi"

client = PeekApi::Client.new(api_key: "ak_live_xxx")

client.track(
  method: "GET",
  path: "/api/users",
  status_code: 200,
  response_time_ms: 42,
)

# Graceful shutdown (flushes remaining events)
client.shutdown
```

## Configuration

| Option | Default | Description |
|---|---|---|
| `api_key` | required | Your PeekAPI key |
| `endpoint` | PeekAPI cloud | Ingestion endpoint URL |
| `flush_interval` | `10` | Seconds between automatic flushes |
| `batch_size` | `100` | Events per HTTP POST (triggers flush) |
| `max_buffer_size` | `10_000` | Max events held in memory |
| `max_storage_bytes` | `5_242_880` | Max disk fallback file size (5MB) |
| `max_event_bytes` | `65_536` | Per-event size limit (64KB) |
| `storage_path` | auto | Custom path for JSONL persistence file |
| `debug` | `false` | Enable debug logging to stderr |
| `on_error` | `nil` | Callback `Proc` invoked with `Exception` on flush errors |

## How It Works

1. Rack middleware intercepts every request/response
2. Captures method, path, status code, response time, request/response sizes, consumer ID
3. Events are buffered in memory and flushed in batches on a background thread
4. On network failure: exponential backoff with jitter, up to 5 retries
5. After max retries: events are persisted to a JSONL file on disk
6. On next startup: persisted events are recovered and re-sent
7. On SIGTERM/SIGINT: remaining buffer is flushed or persisted to disk

## Consumer Identification

By default, consumers are identified by:

1. `X-API-Key` header — stored as-is
2. `Authorization` header — hashed with SHA-256 (stored as `hash_<hex>`)

Override with the `identify_consumer` option to use any header:

```ruby
client = PeekApi::Client.new(
  api_key: "...",
  identify_consumer: ->(headers) { headers["x-tenant-id"] }
)
```

The callback receives a `Hash` of lowercase header names and should return a consumer ID string or `nil`.

## Features

- **Zero runtime dependencies** — uses only Ruby stdlib (`net/http`, `json`, `digest`)
- **Background flush** — dedicated thread with configurable interval and batch size
- **Disk persistence** — undelivered events saved to JSONL, recovered on restart
- **Exponential backoff** — with jitter, max 5 consecutive failures before disk fallback
- **SSRF protection** — private IP blocking, HTTPS enforcement (HTTP only for localhost)
- **Input sanitization** — path (2048), method (16), consumer_id (256) truncation
- **Per-event size limit** — strips metadata first, drops if still too large (default 64KB)
- **Graceful shutdown** — SIGTERM/SIGINT handlers + `at_exit` fallback
- **Rails Railtie** — auto-configures from env vars when Rails is detected

## Requirements

- Ruby >= 3.1

## Contributing

1. Fork & clone the repo
2. Install dependencies — `bundle install`
3. Run tests — `bundle exec rake test`
4. Submit a PR

## License

MIT
