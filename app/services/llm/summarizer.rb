# frozen_string_literal: true

module Llm
  # Produces a structured summary of a document. Demonstrates asking the model
  # for JSON and parsing it defensively, since models do not always return
  # valid JSON even when asked.
  class Summarizer
    class ParseError < StandardError; end

    SYSTEM_PROMPT = <<~PROMPT
      You summarize documents. Respond with ONLY a JSON object of the form:
      {"overview": "one or two sentences", "key_points": ["point", "point"]}
      Do not include markdown fences or any text outside the JSON.
    PROMPT

    def initialize(client: Llm::Client.new)
      @client = client
    end

    # Returns a Hash: { "overview" => String, "key_points" => Array<String> }
    def call(document)
      raw = @client.chat(system: SYSTEM_PROMPT, user: document.content, max_tokens: 512)
      parse(raw)
    end

    private

    # Models sometimes wrap JSON in prose or code fences. Strip the obvious
    # cases, then parse, then fall back to a safe structure rather than raising
    # into the request.
    def parse(raw)
      cleaned = raw.to_s.strip
        .sub(/\A```(?:json)?/, "")
        .sub(/```\z/, "")
        .strip

      data = JSON.parse(cleaned)
      {
        "overview" => data.fetch("overview", "").to_s,
        "key_points" => Array(data["key_points"]).map(&:to_s)
      }
    rescue JSON::ParserError => e
      Rails.logger.warn("[Llm::Summarizer] non-JSON response, returning fallback: #{e.message}")
      { "overview" => cleaned.truncate(300), "key_points" => [] }
    end
  end
end
