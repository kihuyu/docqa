# frozen_string_literal: true

require "rails_helper"

# These specs stub Llm::Client so they are deterministic and never hit the real
# API. The point is to test OUR orchestration (retrieval -> prompt -> parse),
# not the provider's model. This is the pattern to use for any non-deterministic
# external dependency.
RSpec.describe Llm::Answerer do
  let(:client)    { instance_double(Llm::Client) }
  let(:retriever) { instance_double(Llm::Retriever) }
  subject(:answerer) { described_class.new(client: client, retriever: retriever) }

  let(:document) { Document.create!(title: "Policy", content: "...", status: "ready") }

  describe "#call" do
    context "when relevant chunks are found" do
      let(:chunk) do
        document.chunks.create!(content: "Refunds are processed within 5-7 business days.")
      end

      before do
        allow(retriever).to receive(:relevant_chunks).and_return([chunk])
        allow(client).to receive(:chat_with_usage)
          .and_return({ text: "Refunds take 5-7 business days.", tokens_used: 842 })
      end

      it "returns the model's answer" do
        result = answerer.call(document_id: document.id, question: "How long for refunds?")
        expect(result.answer).to eq("Refunds take 5-7 business days.")
      end

      it "includes the source chunks it used" do
        result = answerer.call(document_id: document.id, question: "How long for refunds?")
        expect(result.to_h[:sources].first[:chunk_id]).to eq(chunk.id)
      end

      it "grounds the prompt in the retrieved context" do
        expect(client).to receive(:chat_with_usage) do |system:, user:, **|
          expect(user).to include("5-7 business days")   # context was injected
          { text: "grounded answer", tokens_used: 10 }
        end
        answerer.call(document_id: document.id, question: "How long for refunds?")
      end

      it "reports the tokens used" do
        result = answerer.call(document_id: document.id, question: "How long for refunds?")
        expect(result.to_h[:tokens_used]).to eq(842)
      end
    end

    context "when no relevant chunks are found" do
      before { allow(retriever).to receive(:relevant_chunks).and_return([]) }

      it "does not call the model" do
        expect(client).not_to receive(:chat_with_usage)
        answerer.call(document_id: document.id, question: "Unrelated question?")
      end

      it "returns an honest 'not enough information' answer" do
        result = answerer.call(document_id: document.id, question: "Unrelated question?")
        expect(result.answer).to match(/don't have enough information/i)
      end
    end
  end
end
