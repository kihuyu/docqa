# frozen_string_literal: true

class Chunk < ApplicationRecord
  # `has_neighbors` comes from the `neighbor` gem, which adds
  # `nearest_neighbors` for pgvector similarity search.
  has_neighbors :embedding

  belongs_to :document
  validates :content, presence: true
end
