# frozen_string_literal: true

module Api
  class QueriesController < ApplicationController
    MAX_QUESTION_CHARS = AppSetting.integer(:limits, :max_question_chars,
                                            env: "MAX_QUESTION_CHARS", default: 1000)
    MAX_DOCUMENTS = AppSetting.integer(:limits, :max_documents_per_question, default: 5)

    # Each question costs a Gemini call: cap each visitor, and the whole site.
    rate_limit to: AppSetting.integer(:limits, :questions_per_minute, default: 10), within: 1.minute,
               only: :create, name: "questions-per-visitor",
               store: RATE_LIMIT_STORE, with: -> { render_rate_limited }
    rate_limit to: AppSetting.integer(:limits, :questions_per_day, default: 500), within: 1.day,
               by: -> { "site" }, only: :create, name: "questions-site-wide",
               store: RATE_LIMIT_STORE, with: -> { render_rate_limited(site_wide: true) }

    # POST /api/queries
    # Ask about one document ({ document_id: 1 }) or several
    # ({ document_ids: [1, 2] }, up to MAX_DOCUMENTS).
    def create
      question = params.require(:question).to_s.strip
      ids = requested_document_ids

      if question.empty? || question.length > MAX_QUESTION_CHARS
        return render json: { error: "invalid_question",
                              detail: "question must be 1-#{MAX_QUESTION_CHARS} characters" },
                      status: :unprocessable_entity
      end

      if ids.nil? || ids.empty? || ids.size > MAX_DOCUMENTS
        return render json: { error: "invalid_documents",
                              detail: "choose between 1 and #{MAX_DOCUMENTS} documents" },
                      status: :unprocessable_entity
      end

      documents = Document.where(id: ids).to_a
      missing = ids - documents.map(&:id)
      if missing.any?
        return render json: { error: "not_found", detail: "Couldn't find Document",
                              missing_document_ids: missing },
                      status: :not_found
      end

      # Answering before embedding finishes would just say "not enough
      # information", which is misleading. Tell the caller what's really going on.
      not_ready = documents.reject(&:ready?)
      if not_ready.any?
        return render json: { error: "document_not_ready", status: not_ready.first.status,
                              not_ready_document_ids: not_ready.map(&:id) },
                      status: :conflict
      end

      result = Llm::Answerer.new.call(document_ids: ids, question: question)
      render json: result.to_h
    rescue Llm::Client::Error => e
      # The model call failed after retries. Fail clearly rather than 500.
      render json: { error: "llm_unavailable", detail: e.message }, status: :bad_gateway
    end

    private

    # document_ids (array) or document_id (single, as older clients send).
    # Returns unique integer ids, or nil if any id isn't a whole number.
    def requested_document_ids
      raw = params[:document_ids].presence || params[:document_id]
      raise ActionController::ParameterMissing, :document_id if raw.blank?

      Array(raw).map { |id| Integer(id.to_s, 10) }.uniq
    rescue ArgumentError, TypeError
      nil
    end
  end
end