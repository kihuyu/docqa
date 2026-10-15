# frozen_string_literal: true

require "rails_helper"

# Full-stack request spec for the ask endpoint, with the LLM client stubbed so
# it is deterministic and never hits the network. Exercises routing ->
# controller -> answerer -> JSON contract.
RSpec.describe "POST /api/queries", type: :request do
  let(:document) { Document.create!(title: "Policy", content: "body", status: "ready") }

  let(:chunk) do
    document.chunks.create!(content: "Refunds are processed within 5-7 business days.")
  end

  before do
    allow_any_instance_of(Llm::Retriever).to receive(:relevant_chunks).and_return([chunk])
    allow_any_instance_of(Llm::Client).to receive(:chat_with_usage)
      .and_return({ text: "Refunds take 5-7 business days.", tokens_used: 842 })
  end

  it "returns a grounded answer with sources and token usage" do
    post "/api/queries", params: { document_id: document.id, question: "How long for refunds?" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["answer"]).to match(/5-7 business days/)
    expect(body["sources"].first["chunk_id"]).to eq(chunk.id)
    expect(body["sources"].first["text"]).to eq(chunk.content)
    expect(body["tokens_used"]).to eq(842)
  end

  it "refuses without calling the model when nothing relevant is retrieved" do
    allow_any_instance_of(Llm::Retriever).to receive(:relevant_chunks).and_return([])
    expect_any_instance_of(Llm::Client).not_to receive(:chat_with_usage)

    post "/api/queries", params: { document_id: document.id, question: "Who is the CEO?" }

    body = JSON.parse(response.body)
    expect(body["answer"]).to match(/don't have enough information/i)
    expect(body["sources"]).to eq([])
  end

  it "returns 400 when the question is missing" do
    post "/api/queries", params: { document_id: document.id }
    expect(response).to have_http_status(:bad_request)
  end

  it "returns 422 when the question is too long" do
    long = "a" * (Api::QueriesController::MAX_QUESTION_CHARS + 1)
    post "/api/queries", params: { document_id: document.id, question: long }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "returns 404 for an unknown document" do
    post "/api/queries", params: { document_id: 0, question: "anything?" }
    expect(response).to have_http_status(:not_found)
  end

  it "returns 409 while the document is still being embedded" do
    document.update!(status: "processing")

    post "/api/queries", params: { document_id: document.id, question: "anything?" }

    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body)).to include("error" => "document_not_ready", "status" => "processing")
  end

  it "returns 502 when the model is unavailable" do
    allow_any_instance_of(Llm::Client).to receive(:chat_with_usage)
      .and_raise(Llm::Client::Error, "down")

    post "/api/queries", params: { document_id: document.id, question: "anything?" }
    expect(response).to have_http_status(:bad_gateway)
  end
end
