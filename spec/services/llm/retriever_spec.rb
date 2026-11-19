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

  describe "across several documents" do
    let(:shipping) { Document.create!(title: "Shipping", content: "body", status: "ready") }
    let!(:shipping_best) { shipping.chunks.create!(content: "shipping refunds", embedding: between(0, 3)) }

    it "searches every chosen document and preloads each passage's document" do
      chunks = retriever.relevant_chunks(document_ids: [document.id, shipping.id], question: "refunds?", max_distance: 0.6)

      expect(chunks.map(&:document_id).uniq).to contain_exactly(document.id, shipping.id)
      expect(chunks.first.association(:document)).to be_loaded
    end

    it "gives each document's best passage a place even when another document fills the top" do
      document.chunks.create!(content: "refunds again", embedding: unit_vector(0))

      chunks = retriever.relevant_chunks(document_ids: [document.id, shipping.id], question: "refunds?",
                                         top_k: 2, max_distance: 0.6)

      expect(chunks).to include(shipping_best)
      expect(chunks.size).to eq(2)
    end

    it "requires at least one document" do
      expect { retriever.relevant_chunks(question: "refunds?") }.to raise_error(ArgumentError)
    end

    it "lists every candidate before the cutoff, closest first" do
      found = retriever.candidates(document_ids: [document.id, shipping.id], question: "refunds?")

      # "returns" and "shipping refunds" are equally close, so only the ends
      # have a fixed order.
      expect(found.map(&:content)).to contain_exactly("refunds", "returns", "shipping refunds", "parking")
      expect([found.first.content, found.last.content]).to eq(%w[refunds parking])
      expect(found.map(&:neighbor_distance)).to eq(found.map(&:neighbor_distance).sort)
    end
  end

  describe ".select_passages" do
    Recorded = Struct.new(:document_id, :neighbor_distance)

    it "works on recorded distances, so the evaluation can replay it" do
      recorded = [Recorded.new(:a, 0.1), Recorded.new(:a, 0.12), Recorded.new(:b, 0.3), Recorded.new(:b, 0.9)]

      expect(described_class.select_passages(recorded, top_k: 2, max_distance: 0.5).map(&:to_a))
        .to eq([[:a, 0.1], [:b, 0.3]])
      expect(described_class.select_passages(recorded, top_k: 4, max_distance: 0.2).size).to eq(2)
    end
  end
end