# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Summarizer do
  let(:client) { instance_double(Llm::Client) }
  subject(:summarizer) { described_class.new(client: client, logger: Logger.new(IO::NULL)) }

  let(:document) { Document.new(title: "Policy", content: "Refunds take 5-7 business days.") }

  def stub_reply(text, tokens: 50)
    allow(client).to receive(:chat_with_usage).and_return(text: text, tokens_used: tokens)
  end

  it "parses a clean JSON reply and reports tokens" do
    stub_reply('{"overview":"Refund rules.","key_points":["5-7 days"]}', tokens: 77)

    result = summarizer.call(document)

    expect(result[:summary]).to eq("overview" => "Refund rules.", "key_points" => ["5-7 days"])
    expect(result[:tokens_used]).to eq(77)
    expect(result[:truncated]).to be(false)
  end

  it "asks the client for JSON mode" do
    stub_reply('{"overview":"x","key_points":[]}')
    summarizer.call(document)
    expect(client).to have_received(:chat_with_usage).with(hash_including(json: true))
  end

  it "strips markdown fences" do
    stub_reply("```json\n{\"overview\":\"Fenced.\",\"key_points\":[]}\n```")
    expect(summarizer.call(document)[:summary]["overview"]).to eq("Fenced.")
  end

  it "extracts JSON wrapped in prose" do
    stub_reply('Here you go: {"overview":"Wrapped.","key_points":["a"]} Hope that helps!')
    expect(summarizer.call(document)[:summary]["key_points"]).to eq(["a"])
  end

  it "falls back to a safe structure when the reply is not JSON" do
    stub_reply("Sorry, I can't produce JSON right now.")
    summary = summarizer.call(document)[:summary]
    expect(summary["key_points"]).to eq([])
    expect(summary["overview"]).to include("Sorry")
  end

  it "caps the input it sends and flags the summary as truncated" do
    long_doc = Document.new(title: "Long", content: "a" * (described_class::MAX_INPUT_CHARS + 500))
    stub_reply('{"overview":"x","key_points":[]}')

    result = summarizer.call(long_doc)

    expect(result[:truncated]).to be(true)
    expect(client).to have_received(:chat_with_usage)
      .with(hash_including(user: "a" * described_class::MAX_INPUT_CHARS))
  end
end
