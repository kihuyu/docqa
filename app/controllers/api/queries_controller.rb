# frozen_string_literal: true

module Api
  class QueriesController < ApplicationController
    # POST /api/queries
    def create
      result = Llm::Answerer.new.call(
        document_id: params.require(:document_id),
        question: params.require(:question)
      )
      render json: result.to_h
    rescue Llm::Client::Error => e
      # The model call failed after retries. Fail clearly rather than 500.
      render json: { error: "llm_unavailable", detail: e.message }, status: :bad_gateway
    end
  end
end
