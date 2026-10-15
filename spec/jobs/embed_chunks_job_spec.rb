# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbedChunksJob do
  include ActiveJob::TestHelper

  let(:document) { Document.create!(title: "Policy", content: "body", status: "processing") }
  let(:vector) { Array.new(Llm::Client::EMBED_DIMS, 0.0).tap { |v| v[0] = 1.0 } }

  before do
    document.chunks.create!(content: "chunk one")
    document.chunks.create!(content: "chunk two")
  end

  it "embeds every chunk and marks the document ready" do
    allow_any_instance_of(Llm::Client).to receive(:embed).and_return(vector)

    described_class.perform_now(document.id)

    expect(document.chunks.reload.map(&:embedding)).to all(be_present)
    expect(document.reload.status).to eq("ready")
  end

  it "skips chunks that already have an embedding (so retries resume, not restart)" do
    document.chunks.find_by!(content: "chunk one").update!(embedding: vector)
    embedded = []
    allow_any_instance_of(Llm::Client).to receive(:embed) do |_client, text, **|
      embedded << text
      vector
    end

    described_class.perform_now(document.id)

    expect(embedded).to eq(["chunk two"])
  end

  it "marks the document failed once every retry is used up" do
    allow_any_instance_of(Llm::Client).to receive(:embed).and_raise(Llm::Client::Error, "boom")

    perform_enqueued_jobs { described_class.perform_later(document.id) }

    expect(document.reload.status).to eq("failed")
  end
end
