# frozen_string_literal: true

require "rails_helper"

# Runs real pgvector queries (the test database has the extension) with a
# stubbed client, using hand-made unit vectors so cosine distances are exact:
# same direction = 0.0, perpendicular = 1.0.
RSpec.describe Llm::Retriever do
  let(:client) { instance_double(Llm::Client) }
  subject(:retriever) { described_class.new(client: client, logger: Logger.new(IO::NULL)) }

  let(:dims) { Llm::Client::EMBED_DIMS }
  let(:document) { Document.create!(title: "Policy", content: "body", status: "ready") }

  def unit_vector(index)
    Array.new(dims, 0.0).tap { |v| v[index] = 1.0 }
  end

  # Halfway between two axes: cosine distance ~0.29 from each.
  def between(i, j)
    Array.new(dims, 0.0).tap { |v| v[i] = v[j] = Math.sqrt(0.5) }
  end

  let!(:on_topic)  { document.chunks.create!(content: "refunds", embedding: unit_vector(0)) }
  let!(:nearby)    { document.chunks.create!(content: "returns", embedding: between(0, 1)) }
  let!(:off_topic) { document.chunks.create!(content: "parking", embedding: unit_vector(2)) }

  before { allow(client).to receive(:embed).and_return(unit_vector(0)) }

  it "returns chunks closest first and drops ones beyond the distance cutoff" do
    chunks = retriever.relevant_chunks(document_id: document.id, question: "refunds?", max_distance: 0.6)
    expect(chunks).to eq([on_topic, nearby])
  end

  it "returns nothing when every chunk is too far away" do
    allow(client).to receive(:embed).and_return(unit_vector(5))
    expect(retriever.relevant_chunks(document_id: document.id, question: "CEO?", max_distance: 0.6)).to be_empty
  end

  it "keeps everything when the cutoff is disabled" do
    chunks = retriever.relevant_chunks(document_id: document.id, question: "refunds?", max_distance: nil)
    expect(chunks.size).to eq(3)
  end

  it "ignores chunks that are not embedded yet and other documents' chunks" do
    document.chunks.create!(content: "pending", embedding: nil)
    other = Document.create!(title: "Other", content: "x", status: "ready")
    other.chunks.create!(content: "refunds elsewhere", embedding: unit_vector(0))

    chunks = retriever.relevant_chunks(document_id: document.id, question: "refunds?", max_distance: nil)

    expect(chunks.map(&:document_id).uniq).to eq([document.id])
    expect(chunks.map(&:content)).not_to include("pending")
  end

  it "embeds the question as a query" do
    retriever.relevant_chunks(document_id: document.id, question: "refunds?")
    expect(client).to have_received(:embed).with("refunds?", input_type: "query")
  end
end
