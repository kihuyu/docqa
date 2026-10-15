# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Documents API", type: :request do
  describe "POST /api/documents" do
    it "accepts the document, chunks it, and enqueues embedding" do
      expect {
        post "/api/documents", params: { title: "Policy", content: "Refunds take 5-7 days. " * 60 }
      }.to have_enqueued_job(EmbedChunksJob)

      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("processing")
      expect(body["chunks"]).to be > 1
      expect(Document.find(body["id"]).chunks.count).to eq(body["chunks"])
    end

    it "rejects content over the size limit with 422 and saves nothing" do
      expect {
        post "/api/documents", params: { title: "Huge", content: "a" * (Document::MAX_CONTENT_CHARS + 1) }
      }.not_to change(Document, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 400 when content is missing" do
      post "/api/documents", params: { title: "No body" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /api/documents/:id" do
    it "reports status and embedding progress" do
      document = Document.create!(title: "Policy", content: "body", status: "processing")
      document.chunks.create!(content: "one", embedding: Array.new(Llm::Client::EMBED_DIMS, 0.0).tap { |v| v[0] = 1.0 })
      document.chunks.create!(content: "two")

      get "/api/documents/#{document.id}"

      expect(JSON.parse(response.body)).to include(
        "content" => "body", "status" => "processing", "chunks" => 2, "embedded_chunks" => 1
      )
    end
  end

  describe "POST /api/documents/:id/summary" do
    let(:document) { Document.create!(title: "Policy", content: "Refunds take 5-7 days.", status: "ready") }

    it "returns a structured summary with token usage" do
      allow_any_instance_of(Llm::Client).to receive(:chat_with_usage)
        .and_return(text: '{"overview":"Refund rules.","key_points":["5-7 days"]}', tokens_used: 40)

      post "/api/documents/#{document.id}/summary"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["summary"]).to eq("overview" => "Refund rules.", "key_points" => ["5-7 days"])
      expect(body).to include("truncated" => false, "tokens_used" => 40)
    end

    it "returns 502 when the model is unavailable" do
      allow_any_instance_of(Llm::Client).to receive(:chat_with_usage).and_raise(Llm::Client::Error, "down")

      post "/api/documents/#{document.id}/summary"

      expect(response).to have_http_status(:bad_gateway)
    end
  end
end
