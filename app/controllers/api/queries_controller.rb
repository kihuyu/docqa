# frozen_string_literal: true

module Api
  class QueriesController < ApplicationController
    MAX_QUESTION_CHARS = AppSetting.integer(:limits, :max_question_chars,
                                            env: "MAX_QUESTION_CHARS", default: 1000)
    # POST /api/queries
    def create
      question = params.require(:question).to_s.strip
      document = Document.find(params.require(:document_id))

      if question.empty? || question.length > MAX_QUESTION_CHARS
        return render json: { error: "invalid_question",
                              detail: "question must be 1-#{MAX_QUESTION_CHARS} characters" },
                      status: :unprocessable_entity
      end

      # Answering before embedding finishes would just say "not enough
      # information", which is misleading.
      unless document.ready?
        return render json: { error: "document_not_ready", status: document.status },
                      status: :conflict
      end

      result = Llm::Answerer.new.call(document_id: document.id, question: question)
      render json: result.to_h
    rescue Llm::Client::Error => e
      # The model call failed after retries. Fail clearly rather than 500.
      render json: { error: "llm_unavailable", detail: e.message }, status: :bad_gateway
    end
  end
end
