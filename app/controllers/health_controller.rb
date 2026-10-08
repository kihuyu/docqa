# frozen_string_literal: true

# Liveness probe. Confirms the app boots and the database is reachable.
class HealthController < ApplicationController
  def show
    ActiveRecord::Base.connection.execute("SELECT 1")
    render json: { status: "ok" }
  rescue StandardError => e
    render json: { status: "error", detail: e.message }, status: :service_unavailable
  end
end
