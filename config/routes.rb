# frozen_string_literal: true

Rails.application.routes.draw do
  # Liveness/readiness probe for platform health checks.
  get "/health", to: "health#show"

  namespace :api do
    resources :documents, only: [:create, :show] do
      member { post :summary }
    end
    resources :queries, only: [:create]
  end
end
