# frozen_string_literal: true

class Document < ApplicationRecord
  has_many :chunks, dependent: :destroy

  validates :title, :content, presence: true

  # status: processing -> ready
  def ready?
    status == "ready"
  end
end
