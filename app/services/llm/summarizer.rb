# frozen_string_literal: true

module Llm
  # Produces a structured summary of a document. Asks the model for JSON (using
  # the provider's JSON mode) and still parses defensively, since models do not
  # always return clean JSON even when asked.
  class Summarizer
    # Raised when the model replies but no summary can be found in the reply.
    # A Client::Error, so the controller turns it into a clear 502 instead of
    # the page showing an empty summary.
    class EmptySummary < Llm::Client::Error; end

    # Cost guard: summarize at most this many characters (~7-8k tokens). Longer
    # documents are summarized from their opening portion, and the result says so.
    MAX_INPUT_CHARS = AppSetting.integer(:limits, :summary_max_input_chars,
                                         env: "SUMMARY_MAX_INPUT_CHARS", default: 30_000)

    SYSTEM_PROMPT = <<~PROMPT
      You summarize documents. Respond with ONLY a JSON object of the form:
      {"overview": "one or two sentences", "key_points": ["point", "point"]}
      Use at most 6 key points. Do not include markdown fences or any text
      outside the JSON.
    PROMPT

    def initialize(client: Llm::Client.new, logger: Rails.logger)
      @client = client
      @logger = logger
    end

    # Returns a Hash:
    #   { summary: { "overview" => String, "key_points" => Array<String> },
    #     truncated: Boolean, tokens_used: Integer }
    def call(document)
      content = document.content.to_s
      truncated = content.length > MAX_INPUT_CHARS

      response = @client.chat_with_usage(
        system: SYSTEM_PROMPT,
        user: content[0, MAX_INPUT_CHARS],
        max_tokens: 1024,
        json: true
      )

      { summary: parse(response[:text]), truncated: truncated, tokens_used: response[:tokens_used] }
    end

    private

    OVERVIEW_KEYS = %w[overview summary description abstract].freeze
    POINT_KEYS = %w[keypoints points highlights bullets mainpoints takeaways].freeze

    # Strip code fences, pull out the outermost {...} if the model wrapped it in
    # prose, then parse. Tolerates the shapes models actually return: a wrapper
    # object ({"summary": {...}}), a one-element array, camelCase or other key
    # names, and points given as objects. Non-JSON text becomes the overview.
    # If nothing usable is left, raises EmptySummary rather than returning blanks.
    def parse(raw)
      cleaned = raw.to_s.strip.sub(/\A```(?:json)?/, "").sub(/```\z/, "").strip
      start = cleaned.index("{")
      finish = cleaned.rindex("}")
      candidate = start && finish && finish > start ? cleaned[start..finish] : cleaned

      data = JSON.parse(candidate)
      data = data.first if data.is_a?(Array) && data.first.is_a?(Hash)
      raise JSON::ParserError, "expected a JSON object" unless data.is_a?(Hash)

      data = unwrap(data)
      summary = {
        "overview" => text_of(pick(data, OVERVIEW_KEYS)),
        "key_points" => Array(pick(data, POINT_KEYS)).map { |p| text_of(p) }.reject(&:empty?)
      }
      ensure_present!(summary, raw)
    rescue JSON::ParserError => e
      @logger.warn("[Llm::Summarizer] non-JSON response, using it as plain text: #{e.message}")
      ensure_present!({ "overview" => cleaned.truncate(300), "key_points" => [] }, raw)
    end

    # {"summary": {"overview": ...}} → {"overview": ...}
    def unwrap(data)
      return data if pick(data, OVERVIEW_KEYS).is_a?(String) || pick(data, POINT_KEYS)
      return data unless data.size == 1 && data.values.first.is_a?(Hash)

      data.values.first
    end

    # Finds a key regardless of case, underscores or spaces: keyPoints, key_points
    # and "Key Points" all match "keypoints".
    def pick(data, names)
      key = data.keys.find { |k| names.include?(k.to_s.downcase.gsub(/[^a-z]/, "")) }
      key && data[key]
    end

    def text_of(value)
      case value
      when Hash then value.values.map { |v| text_of(v) }.reject(&:empty?).join(": ")
      when Array then value.map { |v| text_of(v) }.reject(&:empty?).join(" ")
      else value.to_s.strip
      end
    end

    def ensure_present!(summary, raw)
      return summary if summary["overview"].present? || summary["key_points"].any?

      @logger.warn("[Llm::Summarizer] no summary found in reply: #{raw.to_s.truncate(300).inspect}")
      raise EmptySummary, "The model's reply didn't contain a summary. Try again."
    end
  end
end