# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Llm
  # Single entry point for all model calls.
  #
  # Everything that talks to the LLM or embeddings API goes through here so that
  # timeouts, retries, and token logging live in exactly one place. Controllers
  # and other services never call the provider SDK directly.
  #
  # Swap the two `provider_*` private methods to change providers; the public
  # interface (`chat`, `embed`) stays the same.
  class Client
    class Error < StandardError; end
    class RateLimited < Error; end
    class Timeout < Error; end

    MAX_RETRIES = 3
    BASE_DELAY  = 0.5 # seconds; exponential backoff: 0.5, 1.0, 2.0
    TIMEOUT_S   = 30

    # Gemini serves both chat and embeddings from one API, so a single key
    # covers both. Models are env-configurable to tune cost/quality.
    CHAT_MODEL      = Rails.application.credentials.llm_chat_model
    EMBED_MODEL     = Rails.application.credentials.embed_model
    EMBED_DIMS      = Rails.application.credentials.embedding_dims
    API_BASE        = "https://generativelanguage.googleapis.com/v1beta"

    def initialize(api_key: Rails.application.credentials.llm_api_key, logger: Rails.logger)
      @api_key = api_key
      @logger  = logger
    end

    # Returns a chat completion as a String.
    # Raises Llm::Client::Error subclasses on unrecoverable failure.
    def chat(system:, user:, max_tokens: 1024)
      with_retries(:chat) do
        response = provider_chat(system: system, user: user, max_tokens: max_tokens)
        log_tokens(:chat, response[:usage])
        response[:text]
      end
    end

    # Like #chat, but returns a Hash { text:, tokens_used: } so callers that
    # need to report cost (e.g. the query endpoint) can surface token counts.
    def chat_with_usage(system:, user:, max_tokens: 1024)
      with_retries(:chat) do
        response = provider_chat(system: system, user: user, max_tokens: max_tokens)
        log_tokens(:chat, response[:usage])
        { text: response[:text], tokens_used: total_tokens(response[:usage]) }
      end
    end

    # Returns an embedding vector (Array<Float>) for the given text.
    # input_type tunes the vector for its role: "document" when embedding
    # stored chunks, "query" when embedding a search query. Maps to Gemini's
    # taskType (RETRIEVAL_DOCUMENT / RETRIEVAL_QUERY) for better retrieval.
    def embed(text, input_type: "document")
      with_retries(:embed) do
        response = provider_embed(text, input_type: input_type)
        log_tokens(:embed, response[:usage])
        response[:vector]
      end
    end

    private

    attr_reader :api_key, :logger

    # Retry with exponential backoff on transient failures only.
    # Rate limits and timeouts are retried; genuine 4xx errors are not.
    def with_retries(op)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue RateLimited, Timeout => e
        if attempt <= MAX_RETRIES
          delay = BASE_DELAY * (2**(attempt - 1))
          logger.warn("[Llm::Client] #{op} #{e.class} (attempt #{attempt}/#{MAX_RETRIES}), retrying in #{delay}s")
          sleep(delay)
          retry
        end
        logger.error("[Llm::Client] #{op} failed after #{MAX_RETRIES} retries: #{e.message}")
        raise
      end
    end

    def total_tokens(usage)
      return 0 unless usage

      usage[:total_tokens] || (usage[:input_tokens].to_i + usage[:output_tokens].to_i)
    end

    def log_tokens(op, usage)
      return unless usage

      logger.info("[Llm::Client] #{op} tokens=#{total_tokens(usage)}")
    end

    # ----------------------------------------------------------------------
    # Provider-specific calls. Replace the bodies with your SDK of choice.
    # Each must return a hash with the shape the public methods expect and
    # must translate provider errors into the Error subclasses above.
    # ----------------------------------------------------------------------

    # Gemini chat completion via the generateContent REST endpoint.
    # The system prompt goes in systemInstruction; the user turn in contents.
    def provider_chat(system:, user:, max_tokens:)
      body = post_json(
        "#{API_BASE}/models/#{CHAT_MODEL}:generateContent",
        {
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: "user", parts: [{ text: user }] }],
          generationConfig: { maxOutputTokens: max_tokens }
        }
      )

      # A candidate's content has one or more parts; concatenate their text.
      parts = body.dig("candidates", 0, "content", "parts") || []
      text  = parts.map { |p| p["text"] }.compact.join
      usage = body["usageMetadata"] || {}

      {
        text: text,
        usage: {
          input_tokens: usage["promptTokenCount"],
          output_tokens: usage["candidatesTokenCount"]
        }
      }
    rescue Error
      raise
    rescue => e
      raise translate_error(e)
    end

    # Gemini embeddings via embedContent. gemini-embedding-001 is natively
    # 3072-dim but Matryoshka-truncatable, so we request EMBED_DIMS to match the
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

      # gemini-embedding-001 does NOT normalize non-default dimensions, and
      # cosine distance assumes unit vectors — so normalize here.
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

    # Minimal JSON POST. The API key rides in the x-goog-api-key header.
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
      else raise Error, "Gemini HTTP #{response.code}: #{response.body}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise Timeout, "Gemini request timed out"
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
