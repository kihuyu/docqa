# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rate limits", type: :request do
  let(:document) { Document.create!(title: "Policy", content: "body", status: "ready") }

  before do
    allow_any_instance_of(Llm::Retriever).to receive(:relevant_chunks).and_return([])
  end

  it "lets a visitor ask up to the limit, then answers 429 with a reason" do
    limit = AppSetting.integer(:limits, :questions_per_minute, default: 10)

    limit.times do
      post "/api/queries", params: { document_id: document.id, question: "Anything?" }
      expect(response).to have_http_status(:ok)
    end

    post "/api/queries", params: { document_id: document.id, question: "One more?" }
    expect(response).to have_http_status(:too_many_requests)
    expect(JSON.parse(response.body)).to include("error" => "rate_limited")
  end

  it "counts each visitor separately" do
    limit = AppSetting.integer(:limits, :questions_per_minute, default: 10)
    limit.times { post "/api/queries", params: { document_id: document.id, question: "Q?" } }

    post "/api/queries", params: { document_id: document.id, question: "Q?" },
                         env: { "REMOTE_ADDR" => "203.0.113.9" }

    expect(response).to have_http_status(:ok)
  end

  it "limits how many documents a visitor can add" do
    limit = AppSetting.integer(:limits, :documents_per_hour, default: 5)

    limit.times do
      post "/api/documents", params: { title: "Doc", content: "Some text." }
      expect(response).to have_http_status(:accepted)
    end

    post "/api/documents", params: { title: "Doc", content: "Some text." }
    expect(response).to have_http_status(:too_many_requests)
  end
end
