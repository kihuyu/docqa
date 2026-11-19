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
    # Either JSON { title, content } or a multipart upload with `file` (PDF,
    # TXT or Markdown) and an optional `title` (defaults to the file name).
    # Oversized or blank content fails model validation and is rendered as 422
    # by ApplicationController.
    def create
      title, content = document_input
      document = Llm::Ingestor.new.call(title: title, content: content)
      render json: { id: document.id, title: document.title, status: document.status,
                     chunks: document.chunks.size },
             status: :accepted
    rescue TextExtractor::Unreadable => e
      render json: { error: "unreadable_file", detail: e.message }, status: :unprocessable_entity
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

    private

    def document_input
      file = params[:file]
      return [params.require(:title), params.require(:content)] if file.blank?

      unless file.respond_to?(:original_filename)
        raise TextExtractor::Unreadable, "Send the file as a multipart upload in the `file` field."
      end

      extracted = TextExtractor.new.call(io: file.tempfile, filename: file.original_filename)
      [params[:title].presence || extracted[:title], extracted[:content]]
    end
  end
end