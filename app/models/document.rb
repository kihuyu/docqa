# frozen_string_literal: true

class Document < ApplicationRecord
  STATUSES = %w[processing ready failed].freeze

  # Cost guard: every 700 characters becomes an embedding call, and the
  # summarizer reads the content, so cap what one request can ingest.
  MAX_CONTENT_CHARS = AppSetting.integer(:limits, :max_document_chars,
                                         env: "MAX_DOCUMENT_CHARS", default: 200_000)
  has_many :chunks, dependent: :destroy

  validates :title, presence: true, length: { maximum: 300 }
  validates :content, presence: true, length: { maximum: MAX_CONTENT_CHARS }
  validates :status, inclusion: { in: STATUSES }

  # status: processing -> ready, or processing -> failed if embedding gives up
  def ready?
    status == "ready"
  end
end
