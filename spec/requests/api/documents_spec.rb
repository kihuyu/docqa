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

    describe "uploading a file" do
      def upload(bytes, filename, content_type)
        file = Tempfile.new(["upload", File.extname(filename)], binmode: true)
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, content_type, true, original_filename: filename)
      end

      it "adds a PDF, titled after the file" do
        pdf = upload(PdfBuilder.build("Refunds take 5-7 business days."), "returns_policy.pdf", "application/pdf")

        post "/api/documents", params: { file: pdf }

        expect(response).to have_http_status(:accepted)
        document = Document.find(JSON.parse(response.body)["id"])
        expect(document.title).to eq("returns policy")
        expect(document.content).to include("Refunds take 5-7 business days.")
        expect(document.chunks.count).to be >= 1
      end

      it "uses the given title instead of the file name" do
        post "/api/documents", params: { file: upload("Notes", "n.txt", "text/plain"), title: "Team notes" }
        expect(Document.last.title).to eq("Team notes")
      end

      it "explains files it can't read, and saves nothing" do
        expect {
          post "/api/documents", params: { file: upload(PdfBuilder.build(""), "scan.pdf", "application/pdf") }
        }.not_to change(Document, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to include("error" => "unreadable_file")
        expect(JSON.parse(response.body)["detail"]).to match(/no text to read/)
      end
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

    it "returns 502 with a reason when the reply contains no summary" do
      allow_any_instance_of(Llm::Client).to receive(:chat_with_usage).and_return(text: "{}", tokens_used: 5)

      post "/api/documents/#{document.id}/summary"

      expect(response).to have_http_status(:bad_gateway)
      expect(JSON.parse(response.body)["detail"]).to match(/didn't contain a summary/)
    end

    it "returns 502 when the model is unavailable" do
      allow_any_instance_of(Llm::Client).to receive(:chat_with_usage).and_raise(Llm::Client::Error, "down")

      post "/api/documents/#{document.id}/summary"

      expect(response).to have_http_status(:bad_gateway)
    end
  end
end