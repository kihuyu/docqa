class ApplicationController < ActionController::API
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
end
