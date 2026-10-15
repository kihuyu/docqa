# frozen_string_literal: true

module Api
  class DocumentsController < ApplicationController
    # POST /api/documents
    # # Oversized or blank content fails model validation and is rendered as 422
    def create
      document = Llm::Ingestor.new.call(
        title: params.require(:title),
        content: params.require(:content)
      )
      render json: { id: document.id, status: document.status, chunks: document.chunks.size }, status: :accepted
    end

    # GET /api/documents/:id
    def show
      document = Document.find(params[:id])
      render json: {
        id: document.id,
        title: document.title,
        status: document.status,
        chunks: document.chunks.count,
        embedded_chunks: document.chunks.where.not(embedding: nil).count
      }
    end

    # POST /api/documents/:id/summary
    def summary
      document = Document.find(params[:id])
      summary = Llm::Summarizer.new.call(document)
      render json: { summary: summary }
    rescue Llm::Client::Error => e
      render json: { error: "summarization_failed", detail: e.message }, status: :bad_gateway
    end
  end
end
