# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Llm
  # Single entry point for all model calls.
  #
  # Everything that talks to the LLM or embeddings API goes through here so that
  # timeouts, retries, and token/latency logging live in exactly one place.
  # Controllers and other services never call the provider directly.
  #
  # Swap the two `provider_*` private methods to change providers; the public
  # interface (`chat`, `chat_with_usage`, `embed`) stays the same.
  class Client
    class Error < StandardError; end
    class RateLimited < Error; end
    class Timeout < Error; end

    MAX_RETRIES = 3
    BASE_DELAY  = 0.5 # seconds; exponential backoff: ~0.5, ~1.0, ~2.0
    JITTER      = 0.5 # up to +50% random spread so concurrent retries don't stampede
    TIMEOUT_S   = 30

    # Gemini serves both chat and embeddings from one API, so a single key
    # covers both. Settings come from credentials (gemini.*), see AppSetting.
    CHAT_MODEL = AppSetting.fetch(:gemini, :chat_model, env: "LLM_CHAT_MODEL", default: "gemini-2.5-flash")
    EMBED_MODEL = AppSetting.fetch(:gemini, :embeddings_model, env: "EMBEDDINGS_MODEL",
                                   default: "gemini-embedding-001")
    # Must match vector(N) in the chunks migration.
    EMBED_DIMS = AppSetting.integer(:gemini, :embeddings_dims, env: "EMBEDDINGS_DIMS", default: 768)
    API_BASE = "https://generativelanguage.googleapis.com/v1beta"

    # Gemini 2.5 models "think" before answering, and thinking tokens count
    # against maxOutputTokens — a small budget can be eaten entirely by thinking
    # and return no text. Grounded Q&A doesn't need it, so default to 0 (off).
    # Set gemini.thinking_budget to a number to allow some, or to false to omit
    # the setting for models that reject it. nil here means "don't send it".
    THINKING_BUDGET = AppSetting.optional(:gemini, :thinking_budget, env: "LLM_THINKING_BUDGET",
                                          default: 0) { |v| Integer(v) }

    def initialize(api_key: self.class.default_api_key, logger: Rails.logger)
      @api_key = api_key
      @logger  = logger
    end

    # The Gemini key, from credentials (gemini.api_key), falling back to the
    # LLM_API_KEY env var for CI and tests.
    def self.default_api_key
      AppSetting.fetch(:gemini, :api_key, env: "LLM_API_KEY").presence ||
        raise(Error, "No Gemini API key. Add gemini.api_key with " \
          "`bin/rails credentials:edit`, or set LLM_API_KEY.")
    end

    # Returns a chat completion as a String.
    # Raises Llm::Client::Error subclasses on unrecoverable failure.
    def chat(system:, user:, max_tokens: 1024, json: false)
      chat_with_usage(system: system, user: user, max_tokens: max_tokens, json: json)[:text]
    end

    # Like #chat, but returns a Hash { text:, tokens_used: } so callers that
    # need to report cost (e.g. the query endpoint) can surface token counts.
    # Pass json: true to ask the provider for a JSON-only response.
    def chat_with_usage(system:, user:, max_tokens: 1024, json: false)
      with_retries(:chat) do
        response = timed(:chat) do
          provider_chat(system: system, user: user, max_tokens: max_tokens, json: json)
        end
        { text: response[:text], tokens_used: total_tokens(response[:usage]) }
      end
    end

    # Returns an embedding vector (Array<Float>) for the given text.
    # input_type tunes the vector for its role: "document" when embedding
    # stored chunks, "query" when embedding a search query. Maps to Gemini's
    # taskType (RETRIEVAL_DOCUMENT / RETRIEVAL_QUERY) for better retrieval.
    def embed(text, input_type: "document")
      with_retries(:embed) do
        timed(:embed) { provider_embed(text, input_type: input_type) }[:vector]
      end
    end

    private

    attr_reader :api_key, :logger

    # Retry with exponential backoff + jitter on transient failures only.
    # Rate limits, timeouts and 5xx are retried; genuine 4xx errors are not.
    def with_retries(op)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue RateLimited, Timeout => e
        if attempt <= MAX_RETRIES
          delay = backoff_delay(attempt)
          logger.warn("[Llm::Client] op=#{op} #{e.class.name.demodulize} " \
                        "attempt=#{attempt}/#{MAX_RETRIES} retry_in=#{delay.round(2)}s")
          sleep(delay)
          retry
        end
        logger.error("[Llm::Client] op=#{op} gave_up after=#{MAX_RETRIES} retries: #{e.message}")
        raise
      end
    end

    # 0.5s, 1s, 2s ... each stretched by a random 0-50% so that many workers
    # hitting the same rate limit at once don't all retry in the same instant.
    def backoff_delay(attempt)
      base = BASE_DELAY * (2**(attempt - 1))
      base + (base * JITTER * rand)
    end

    # Runs one provider call and emits a single structured log line with the
    # op, model, token counts and latency — enough to answer "what did that
    # request cost and how slow was it?" straight from the logs.
    def timed(op)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = yield
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      usage = response[:usage] || {}
      model = op == :chat ? CHAT_MODEL : EMBED_MODEL

      parts = ["[Llm::Client] op=#{op} model=#{model} ms=#{ms}"]
      parts << "tokens_in=#{usage[:input_tokens]}" if usage[:input_tokens]
      parts << "tokens_out=#{usage[:output_tokens]}" if usage[:output_tokens]
      parts << "tokens_thinking=#{usage[:thinking_tokens]}" if usage[:thinking_tokens].to_i.positive?
      parts << "tokens_total=#{total_tokens(usage)}" if usage.any?
      logger.info(parts.join(" "))

      response
    end

    def total_tokens(usage)
      return 0 if usage.blank?

      usage[:total_tokens] ||
        (usage[:input_tokens].to_i + usage[:output_tokens].to_i + usage[:thinking_tokens].to_i)
    end

    # ----------------------------------------------------------------------
    # Provider-specific calls. Replace the bodies to change provider.
    # Each must return a hash with the shape the public methods expect and
    # must translate provider errors into the Error subclasses above.
    # ----------------------------------------------------------------------

    # Gemini chat completion via the generateContent REST endpoint.
    # The system prompt goes in systemInstruction; the user turn in contents.
    def provider_chat(system:, user:, max_tokens:, json: false)
      body = post_json(
        "#{API_BASE}/models/#{CHAT_MODEL}:generateContent",
        {
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: "user", parts: [{ text: user }] }],
          generationConfig: generation_config(max_tokens, json: json)
        }
      )

      parse_chat_response(body)
    rescue Error
      raise
    rescue => e
      raise translate_error(e)
    end

    def generation_config(max_tokens, json: false)
      config = { maxOutputTokens: max_tokens }
      config[:responseMimeType] = "application/json" if json
      config[:thinkingConfig] = { thinkingBudget: THINKING_BUDGET } unless THINKING_BUDGET.nil?
      config
    end

    # Pulls the answer text and token usage out of a generateContent response.
    # Raises a clear error instead of returning "" when the model produced no
    # text, e.g. the prompt was blocked, or the output budget ran out.
    def parse_chat_response(body)
      if (block = body.dig("promptFeedback", "blockReason"))
        raise Error, "Gemini blocked the prompt (#{block})"
      end

      candidate = body.dig("candidates", 0) || {}
      parts = candidate.dig("content", "parts") || []
      # Skip any "thought" parts; only real answer text goes back to the caller.
      text = parts.reject { |p| p["thought"] }.map { |p| p["text"] }.compact.join

      if text.strip.empty?
        reason = candidate["finishReason"] || "unknown"
        raise Error, "Gemini returned no text (finishReason=#{reason})"
      end

      usage = body["usageMetadata"] || {}
      {
        text: text,
        usage: {
          input_tokens: usage["promptTokenCount"],
          output_tokens: usage["candidatesTokenCount"],
          thinking_tokens: usage["thoughtsTokenCount"]
        }
      }
    end

    # Gemini embeddings via embedContent. gemini-embedding-001 is natively
    # 3072-dim but we request EMBED_DIMS to match the
    # migration's vector(N). taskType tunes the vector for its retrieval role.
    def provider_embed(text, input_type: "document")
      task = input_type == "query" ? "RETRIEVAL_QUERY" : "RETRIEVAL_DOCUMENT"

      body = post_json(
        "#{API_BASE}/models/#{EMBED_MODEL}:embedContent",
        {
          model: "models/#{EMBED_MODEL}",
          content: { parts: [{ text: text }] },
          taskType: task,
          outputDimensionality: EMBED_DIMS
        }
      )

      vector = body.dig("embedding", "values")
      raise Error, "embeddings response missing vector" if vector.nil?

      if vector.length != EMBED_DIMS
        raise Error, "embedding has #{vector.length} dims, expected #{EMBED_DIMS} " \
          "(EMBEDDINGS_DIMS must match vector(N) in the migration)"
      end

      # gemini-embedding-001 does NOT normalize non-default dimensions, and
      # cosine distance assumes unit vectors — so normalize here.
      # (embedContent doesn't report token usage, so usage is empty.)
      { vector: l2_normalize(vector), usage: {} }
    rescue Error
      raise
    rescue => e
      raise translate_error(e)
    end

    # Scale a vector to unit length so cosine distance behaves correctly.
    def l2_normalize(vector)
      norm = Math.sqrt(vector.sum { |x| x * x })
      return vector if norm.zero?

      vector.map { |x| x / norm }
    end

    # Minimal JSON POST. The API key rides in the x-goog-api-key header (never
    # in the URL, so it can't leak into proxy or access logs).
    def post_json(url, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = TIMEOUT_S
      http.read_timeout = TIMEOUT_S

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["x-goog-api-key"] = api_key
      request.body = JSON.generate(payload)

      response = http.request(request)

      case response.code.to_i
      when 200..299 then JSON.parse(response.body)
      when 429      then raise RateLimited, "Gemini rate limited"
      when 500..599 then raise Timeout, "Gemini server error #{response.code}"
      else raise Error, "Gemini HTTP #{response.code}: #{error_message(response.body)}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise Timeout, "Gemini request timed out"
    end

    # Gemini errors look like {"error": {"message": "..."}}; surface just the
    # message, and cap length so a huge body can't flood logs or responses.
    def error_message(raw)
      JSON.parse(raw).dig("error", "message") || raw.to_s.truncate(300)
    rescue JSON::ParserError
      raw.to_s.truncate(300)
    end

    # Map transport exceptions onto our retryable/non-retryable taxonomy.
    # 429s and timeouts are retried by with_retries; other errors are not.
    def translate_error(error)
      name = error.class.name.to_s
      case
      when name.include?("RateLimit") || error.message.to_s =~ /rate.?limit|429/i
        RateLimited.new(error.message)
      when error.is_a?(Timeout) || name.include?("Timeout")
        Timeout.new(error.message)
      when error.is_a?(Error)
        error
      else
        Error.new("#{error.class}: #{error.message}")
      end
    end
  end
end