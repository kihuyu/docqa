# frozen_string_literal: true

# Embeds all chunks of a document in the background so ingestion does not block
# the request. Runs on Active Job (Solid Queue adapter); transient API failures
# are handled inside the LLM client, and the job retries on unexpected errors.
class EmbedChunksJob < ApplicationJob
  queue_as :embeddings

  # Retry a few times on unexpected failures, backing off between attempts.
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  # A deleted document is not an error worth retrying.
  discard_on ActiveRecord::RecordNotFound

  def perform(document_id)
    document = Document.find(document_id)
    client = Llm::Client.new

    document.chunks.where(embedding: nil).find_each do |chunk|
      vector = client.embed(chunk.content)
      chunk.update!(embedding: vector)
    end

    document.update!(status: "ready")
  end
end
