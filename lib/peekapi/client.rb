# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'digest/sha2'
require 'tempfile'
require 'fileutils'

module PeekApi
  class Client
    # --- Constants ---
    DEFAULT_ENDPOINT = 'https://ingest.peekapi.dev/v1/events'
    DEFAULT_FLUSH_INTERVAL = 15 # seconds
    DEFAULT_BATCH_SIZE = 250
    DEFAULT_MAX_BUFFER_SIZE = 10_000
    DEFAULT_MAX_STORAGE_BYTES = 5_242_880  # 5 MB
    DEFAULT_MAX_EVENT_BYTES = 65_536       # 64 KB
    MAX_PATH_LENGTH = 2_048
    MAX_METHOD_LENGTH = 16
    MAX_CONSUMER_ID_LENGTH = 256
    MAX_CONSECUTIVE_FAILURES = 5
    BASE_BACKOFF_S = 1.0
    SEND_TIMEOUT_S = 5
    DISK_RECOVERY_INTERVAL_S = 60
    RETRYABLE_STATUS_CODES = [429, 500, 502, 503, 504].freeze

    attr_reader :api_key, :endpoint, :identify_consumer, :collect_query_string

    # @param options [Hash]
    # @option options [String] :api_key  Required. Your API key.
    # @option options [String] :endpoint Ingestion endpoint URL (default: PeekAPI cloud).
    # @option options [Numeric] :flush_interval  Seconds between background flushes (default 15).
    # @option options [Integer] :batch_size       Max events per HTTP POST (default 250).
    # @option options [Integer] :max_buffer_size  Max buffered events (default 10_000).
    # @option options [Integer] :max_storage_bytes Max bytes for disk persistence (default 5 MB).
    # @option options [Integer] :max_event_bytes  Max bytes per single event (default 64 KB).
    # @option options [String]  :storage_path     Custom path for JSONL persistence file.
    # @option options [Boolean] :debug            Enable debug logging to $stderr.
    # @option options [Proc]    :on_error         Callback invoked with Exception on flush failure.
    def initialize(options = {})
      @api_key = options[:api_key] || options['api_key']
      raise ArgumentError, 'api_key is required' if @api_key.nil? || @api_key.empty?
      raise ArgumentError, 'api_key contains invalid control characters' if @api_key.match?(/[\x00-\x1f\x7f]/)

      raw_endpoint = options[:endpoint] || options['endpoint'] || DEFAULT_ENDPOINT
      @endpoint = SSRF.validate_endpoint!(raw_endpoint)

      @flush_interval = (options[:flush_interval] || options['flush_interval'] || DEFAULT_FLUSH_INTERVAL).to_f
      @batch_size = (options[:batch_size] || options['batch_size'] || DEFAULT_BATCH_SIZE).to_i
      @max_buffer_size = (options[:max_buffer_size] || options['max_buffer_size'] || DEFAULT_MAX_BUFFER_SIZE).to_i
      @max_storage_bytes =
        (options[:max_storage_bytes] || options['max_storage_bytes'] || DEFAULT_MAX_STORAGE_BYTES).to_i
      @max_event_bytes = (options[:max_event_bytes] || options['max_event_bytes'] || DEFAULT_MAX_EVENT_BYTES).to_i
      @debug = options[:debug] || options['debug'] || false
      @identify_consumer = options[:identify_consumer] || options['identify_consumer']
      @on_error = options[:on_error] || options['on_error']
      # NOTE: increases DB usage — each unique path+query creates a separate endpoint row.
      @collect_query_string = options[:collect_query_string] || options['collect_query_string'] || false

      # Storage path
      storage = options[:storage_path] || options['storage_path']
      if storage
        @storage_path = storage
      else
        h = Digest::SHA256.hexdigest(@endpoint)[0, 12]
        @storage_path = File.join(Dir.tmpdir, "peekapi-events-#{h}.jsonl")
      end

      @recovery_path = nil

      # Internal state
      @buffer = []
      @mutex = Mutex.new
      @in_flight = false
      @consecutive_failures = 0
      @backoff_until = 0.0
      @shutdown = false
      @last_disk_recovery = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Load persisted events from disk
      load_from_disk

      # Background flush thread
      @done = false
      @wake = Queue.new
      @thread = Thread.new { run_loop }

      # Signal handlers (only from main thread)
      @original_handlers = {}
      if Thread.current == Thread.main
        %i[TERM INT].each do |sig|
          prev = Signal.trap(sig) { signal_handler(sig) }
          @original_handlers[sig] = prev
        rescue ArgumentError
          # Signal not supported on this platform
        end
      end

      # at_exit fallback
      at_exit { shutdown_sync }
    end

    # Buffer an analytics event. Never raises.
    def track(event)
      track_inner(event)
    rescue StandardError => e
      warn "peekapi: track() error: #{e.message}" if @debug
    end

    # Flush buffered events synchronously (blocks until complete).
    def flush
      batch = drain_batch
      return if batch.empty?

      do_flush(batch)
    end

    # Graceful shutdown: stop thread, final flush, persist remainder.
    def shutdown
      return if @shutdown

      @shutdown = true

      # Remove signal handlers
      @original_handlers.each do |sig, handler|
        Signal.trap(sig, handler)
      rescue ArgumentError
        # ignore
      end
      @original_handlers.clear

      # Stop background thread
      @done = true
      @wake << :stop
      @thread.join(5)

      # Final flush
      flush

      # Persist remainder
      remaining = @mutex.synchronize do
        buf = @buffer.dup
        @buffer.clear
        buf
      end
      persist_to_disk(remaining) unless remaining.empty?
    end

    private

    # ----------------------------------------------------------------
    # Track internals
    # ----------------------------------------------------------------

    def track_inner(event)
      return if @shutdown

      d = event.is_a?(Hash) ? event.transform_keys(&:to_s) : event.to_h.transform_keys(&:to_s)

      # Sanitize
      d['method'] = d.fetch('method', '').to_s[0, MAX_METHOD_LENGTH].upcase
      d['path'] = d.fetch('path', '').to_s[0, MAX_PATH_LENGTH]
      d['consumer_id'] = d['consumer_id'].to_s[0, MAX_CONSUMER_ID_LENGTH] if d['consumer_id']

      # Timestamp
      d['timestamp'] ||= Time.now.utc.iso8601(3)

      # Per-event size limit
      raw = JSON.generate(d)
      if raw.bytesize > @max_event_bytes
        d.delete('metadata')
        raw = JSON.generate(d)
        if raw.bytesize > @max_event_bytes
          warn "peekapi: event too large, dropping (#{raw.bytesize} bytes)" if @debug
          return
        end
      end

      @mutex.synchronize do
        if @buffer.size >= @max_buffer_size
          # Buffer full — trigger flush instead of dropping
          @wake << :flush
          return
        end
        @buffer << d
        size = @buffer.size
        @wake << :flush if size >= @batch_size
      end
    end

    # ----------------------------------------------------------------
    # Flush internals
    # ----------------------------------------------------------------

    def drain_batch
      @mutex.synchronize do
        return [] if @buffer.empty? || @in_flight

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return [] if now < @backoff_until

        batch = @buffer.shift(@batch_size)
        @in_flight = true
        batch
      end
    end

    def do_flush(batch)
      send_events(batch)

      # Success
      @mutex.synchronize do
        @consecutive_failures = 0
        @backoff_until = 0.0
        @in_flight = false
      end
      cleanup_recovery_file
      warn "peekapi: flushed #{batch.size} events" if @debug
    rescue NonRetryableError => e
      @mutex.synchronize { @in_flight = false }
      persist_to_disk(batch)
      call_on_error(e)
      warn "peekapi: non-retryable error, persisted to disk: #{e.message}" if @debug
    rescue StandardError => e
      failures = @mutex.synchronize do
        @consecutive_failures += 1
        f = @consecutive_failures

        if f >= MAX_CONSECUTIVE_FAILURES
          @consecutive_failures = 0
          @in_flight = false
          persist_to_disk(batch)
        else
          # Re-insert at front
          space = @max_buffer_size - @buffer.size
          reinsert = batch[0, space]
          @buffer.unshift(*reinsert) unless reinsert.empty?
          # Exponential backoff with jitter
          delay = BASE_BACKOFF_S * (2**(f - 1)) * rand(0.5..1.0)
          @backoff_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + delay
          @in_flight = false
        end

        f
      end

      call_on_error(e)
      warn "peekapi: flush failed (attempt #{failures}): #{e.message}" if @debug
    end

    def send_events(events)
      uri = URI.parse(@endpoint)
      body = JSON.generate(events)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = SEND_TIMEOUT_S
      http.read_timeout = SEND_TIMEOUT_S

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = @api_key
      request['x-peekapi-sdk'] = "ruby/#{VERSION}"
      request.body = body

      response = http.request(request)
      status = response.code.to_i

      if status >= 200 && status < 300
        nil
      elsif RETRYABLE_STATUS_CODES.include?(status)
        raise RetryableError, "HTTP #{status}: #{response.body&.[](0, 1024)}"
      else
        raise NonRetryableError, "HTTP #{status}: #{response.body&.[](0, 1024)}"
      end
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
           Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise RetryableError, "Network error: #{e.message}"
    end

    # ----------------------------------------------------------------
    # Background thread
    # ----------------------------------------------------------------

    def run_loop
      until @done
        # Wait for wake signal or timeout
        begin
          @wake.pop(timeout: @flush_interval)
        rescue ThreadError
          # Timeout — proceed to flush
        end
        break if @done

        batch = drain_batch
        do_flush(batch) unless batch.empty?

        # Periodically recover persisted events from disk
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now - @last_disk_recovery >= DISK_RECOVERY_INTERVAL_S
          @last_disk_recovery = now
          load_from_disk
        end
      end
    end

    # ----------------------------------------------------------------
    # Disk persistence
    # ----------------------------------------------------------------

    def persist_to_disk(events)
      return if events.empty?

      path = @storage_path
      size = begin
        File.size(path)
      rescue StandardError
        0
      end

      if size >= @max_storage_bytes
        warn "peekapi: storage file full, dropping #{events.size} events" if @debug
        return
      end

      line = "#{JSON.generate(events)}\n"
      File.open(path, 'a', 0o600) { |f| f.write(line) }
    rescue StandardError => e
      warn "peekapi: disk persist failed: #{e.message}" if @debug
    end

    def load_from_disk
      recovery = "#{@storage_path}.recovering"

      [recovery, @storage_path].each do |path|
        next unless File.file?(path)

        begin
          content = File.read(path, encoding: 'utf-8')
          events = []
          content.each_line do |line|
            line = line.strip
            next if line.empty?

            begin
              parsed = JSON.parse(line)
              if parsed.is_a?(Array)
                events.concat(parsed)
              elsif parsed.is_a?(Hash)
                events << parsed
              end
            rescue JSON::ParserError
              next
            end
            break if events.size >= @max_buffer_size
          end

          unless events.empty?
            @mutex.synchronize do
              space = @max_buffer_size - @buffer.size
              @buffer.concat(events[0, space]) if space.positive?
            end
            warn "peekapi: loaded #{events.size} events from disk" if @debug
          end

          # Rename to .recovering so we don't double-load
          if path == @storage_path
            rpath = "#{@storage_path}.recovering"
            begin
              File.rename(path, rpath)
            rescue SystemCallError
              begin
                File.delete(path)
              rescue StandardError
                nil
              end
            end
            @recovery_path = rpath
          else
            @recovery_path = path
          end

          break # loaded from one file, done
        rescue StandardError => e
          warn "peekapi: disk load failed from #{path}: #{e.message}" if @debug
        end
      end
    end

    def cleanup_recovery_file
      return unless @recovery_path

      begin
        File.delete(@recovery_path)
      rescue StandardError
        nil
      end
      @recovery_path = nil
    end

    # ----------------------------------------------------------------
    # Signal / at_exit handlers
    # ----------------------------------------------------------------

    def signal_handler(sig)
      shutdown_sync
      # Re-raise with original handler
      handler = @original_handlers[sig]
      if handler.is_a?(Proc)
        handler.call
      elsif handler == 'DEFAULT'
        Signal.trap(sig, 'DEFAULT')
        Process.kill(sig, Process.pid)
      end
    end

    def shutdown_sync
      return if @shutdown

      @shutdown = true
      @done = true
      begin
        @wake << :stop
      rescue StandardError
        nil
      end

      remaining = @mutex.synchronize do
        buf = @buffer.dup
        @buffer.clear
        buf
      end
      persist_to_disk(remaining) unless remaining.empty?
    end

    # ----------------------------------------------------------------
    # Helpers
    # ----------------------------------------------------------------

    def call_on_error(exc)
      return unless @on_error

      begin
        @on_error.call(exc)
      rescue StandardError
        nil
      end
    end

    # Error classes
    class RetryableError < StandardError; end
    class NonRetryableError < StandardError; end
  end
end
