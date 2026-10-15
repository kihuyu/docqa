# frozen_string_literal: true

class ApplicationController < ActionController::API
  # Where rate_limit keeps its counts. A dedicated in-memory store, so limits
  # work whatever Rails.cache is set to. Counts reset when the app restarts,
  # which is fine for keeping a public demo inside its free API quota.
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new(size: 8.megabytes)

  # Turn common lookup/validation failures into clean JSON instead of 500s.
  rescue_from ActiveRecord::RecordNotFound do |e|
    render json: { error: "not_found", detail: e.message }, status: :not_found
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    render json: { error: "invalid", detail: e.message }, status: :unprocessable_entity
  end

  rescue_from ActionController::ParameterMissing do |e|
    render json: { error: "parameter_missing", detail: e.message }, status: :bad_request
  end

  private

  # Response for rate_limit's `with:`. site_wide: the whole demo hit its cap,
  # not just this visitor.
  def render_rate_limited(site_wide: false)
    detail = if site_wide
               "This public demo has reached its usage limit for now. Try again later."
             else
               "You're sending requests faster than this demo allows. Wait a minute and try again."
             end
    render json: { error: "rate_limited", detail: detail }, status: :too_many_requests
  end
end
