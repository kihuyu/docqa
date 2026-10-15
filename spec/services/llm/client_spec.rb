# frozen_string_literal: true

require "rails_helper"

# Tests the client's own logic — retries, backoff, response parsing, error
# mapping — without hitting a real API, by stubbing the private provider and
# HTTP methods. Demonstrates testing resilience logic directly.
RSpec.describe Llm::Client do
  subject(:client) { described_class.new(api_key: "test", logger: Logger.new(IO::NULL)) }

  before { allow(client).to receive(:sleep) } # don't actually wait in tests

  def unit_vector(index, dims = described_class::EMBED_DIMS)
    Array.new(dims, 0.0).tap { |v| v[index] = 1.0 }
  end

  describe "#chat retry behaviour" do
    it "retries on rate limit, then succeeds" do
      call_count = 0
      allow(client).to receive(:provider_chat) do
        call_count += 1
        raise Llm::Client::RateLimited if call_count < 3

        { text: "ok", usage: { total_tokens: 10 } }
      end

      expect(client.chat(system: "s", user: "u")).to eq("ok")
      expect(call_count).to eq(3)
    end

    it "gives up after MAX_RETRIES and raises" do
      allow(client).to receive(:provider_chat).and_raise(Llm::Client::Timeout)

      expect { client.chat(system: "s", user: "u") }.to raise_error(Llm::Client::Timeout)
      expect(client).to have_received(:provider_chat).exactly(described_class::MAX_RETRIES + 1).times
    end

    it "does not retry on a non-transient error" do
      call_count = 0
      allow(client).to receive(:provider_chat) do
        call_count += 1
        raise Llm::Client::Error, "bad request"
      end

      expect { client.chat(system: "s", user: "u") }.to raise_error(Llm::Client::Error)
      expect(call_count).to eq(1) # no retries
    end
  end

  describe "backoff delay" do
    it "grows exponentially and adds at most 50% jitter" do
      [[1, 0.5], [2, 1.0], [3, 2.0]].each do |attempt, base|
        20.times do
          delay = client.send(:backoff_delay, attempt)
          expect(delay).to be_between(base, base * 1.5)
        end
      end
    end
  end

  describe "#chat_with_usage" do
    it "returns text and total tokens including thinking tokens" do
      allow(client).to receive(:provider_chat).and_return(
        text: "hi", usage: { input_tokens: 100, output_tokens: 20, thinking_tokens: 5 }
      )

      expect(client.chat_with_usage(system: "s", user: "u")).to eq(text: "hi", tokens_used: 125)
    end

    it "logs one structured line with tokens and latency" do
      io = StringIO.new
      logged = described_class.new(api_key: "test", logger: Logger.new(io))
      allow(logged).to receive(:provider_chat).and_return(
        text: "hi", usage: { input_tokens: 100, output_tokens: 20 }
      )

      logged.chat(system: "s", user: "u")

      expect(io.string).to match(/op=chat model=\S+ ms=\d+ tokens_in=100 tokens_out=20 tokens_total=120/)
    end
  end

  describe "parsing a Gemini chat response" do
    def parse(body)
      client.send(:parse_chat_response, body)
    end

    it "joins answer parts and skips thought parts" do
      body = {
        "candidates" => [{ "content" => { "parts" => [
          { "text" => "thinking...", "thought" => true },
          { "text" => "Refunds take " },
          { "text" => "5-7 days." }
        ] } }],
        "usageMetadata" => { "promptTokenCount" => 50, "candidatesTokenCount" => 6, "thoughtsTokenCount" => 3 }
      }

      result = parse(body)
      expect(result[:text]).to eq("Refunds take 5-7 days.")
      expect(result[:usage]).to eq(input_tokens: 50, output_tokens: 6, thinking_tokens: 3)
    end

    it "raises instead of returning empty text, naming the finish reason" do
      body = { "candidates" => [{ "finishReason" => "MAX_TOKENS", "content" => { "parts" => [] } }] }
      expect { parse(body) }.to raise_error(Llm::Client::Error, /finishReason=MAX_TOKENS/)
    end

    it "raises when the prompt was blocked" do
      body = { "promptFeedback" => { "blockReason" => "SAFETY" } }
      expect { parse(body) }.to raise_error(Llm::Client::Error, /blocked.*SAFETY/)
    end
  end

  describe "request config" do
    it "asks for JSON output when json: true" do
      expect(client.send(:generation_config, 512, json: true)).to include(responseMimeType: "application/json")
    end

    it "omits JSON mode by default" do
      expect(client.send(:generation_config, 512)).not_to have_key(:responseMimeType)
    end
  end

  describe "#embed" do
    it "returns a unit-length vector" do
      raw = unit_vector(0).tap { |v| v[1] = 1.0 } # length sqrt(2), not normalized
      allow(client).to receive(:post_json).and_return("embedding" => { "values" => raw })

      vector = client.embed("hello")

      expect(vector.length).to eq(described_class::EMBED_DIMS)
      expect(Math.sqrt(vector.sum { |x| x * x })).to be_within(1e-9).of(1.0)
    end

    it "sends the retrieval task type for queries" do
      allow(client).to receive(:post_json).and_return("embedding" => { "values" => unit_vector(0) })

      client.embed("a question", input_type: "query")

      expect(client).to have_received(:post_json).with(anything, hash_including(taskType: "RETRIEVAL_QUERY"))
    end

    it "fails loudly on a dimension mismatch instead of writing a bad vector" do
      allow(client).to receive(:post_json).and_return("embedding" => { "values" => [0.1, 0.2, 0.3] })

      expect { client.embed("hello") }.to raise_error(Llm::Client::Error, /3 dims, expected/)
    end
  end

  describe "error messages" do
    it "extracts Gemini's error message from the JSON body" do
      body = { error: { message: "API key not valid. Please pass a valid API key." } }.to_json
      expect(client.send(:error_message, body)).to eq("API key not valid. Please pass a valid API key.")
    end

    it "truncates non-JSON bodies" do
      expect(client.send(:error_message, "x" * 1000).length).to be <= 300
    end
  end
end
