# frozen_string_literal: true

module Api
  class DocumentsController < ApplicationController
    # Adding a document costs one Gemini call per passage, a summary one more.
    rate_limit to: AppSetting.integer(:limits, :documents_per_hour, default: 5), within: 1.hour,
               only: :create, name: "documents-per-visitor",
               store: RATE_LIMIT_STORE, with: -> { render_rate_limited }
    rate_limit to: AppSetting.integer(:limits, :documents_per_day, default: 50), within: 1.day,
               by: -> { "site" }, only: :create, name: "documents-site-wide",
               store: RATE_LIMIT_STORE, with: -> { render_rate_limited(site_wide: true) }
    rate_limit to: AppSetting.integer(:limits, :summaries_per_hour, default: 10), within: 1.hour,
               only: :summary, name: "summaries-per-visitor",
               store: RATE_LIMIT_STORE, with: -> { render_rate_limited }

    # POST /api/documents
    # Oversized or blank content fails model validation and is rendered as 422
    # by ApplicationController.
    def create
      document = Llm::Ingestor.new.call(
        title: params.require(:title),
        content: params.require(:content)
      )
      render json: { id: document.id, status: document.status, chunks: document.chunks.size },
             status: :accepted
    end

    # GET /api/documents/:id
    def show
      document = Document.find(params[:id])
      render json: {
        id: document.id,
        title: document.title,
        content: document.content,
        status: document.status,
        chunks: document.chunks.count,
        embedded_chunks: document.chunks.where.not(embedding: nil).count
      }
    end

    # POST /api/documents/:id/summary
    def summary
      document = Document.find(params[:id])
      result = Llm::Summarizer.new.call(document)
      render json: result
    rescue Llm::Client::Error => e
      render json: { error: "summarization_failed", detail: e.message }, status: :bad_gateway
    end
  end
end