# frozen_string_literal: true

module Llm
  # Splits a document into overlapping chunks and enqueues background embedding.
  # Returns immediately; embedding happens in EmbedChunksJob.
  class Ingestor
    CHUNK_SIZE = 800    # characters; simple and good enough for an MVP
    OVERLAP    = 100    # keep some context across chunk boundaries

    def call(title:, content:)
      document = Document.create!(title: title, content: content, status: "processing")

      chunks_for(content).each do |text|
        document.chunks.create!(content: text)
      end

      EmbedChunksJob.perform_later(document.id)
      document
    end

    private

    # Character-based sliding window. A production version might split on
    # sentence or paragraph boundaries, but this is clear and predictable.
    def chunks_for(content)
      text = content.to_s
      return [] if text.empty?

      step = CHUNK_SIZE - OVERLAP
      (0...text.length).step(step).map { |i| text[i, CHUNK_SIZE] }.reject(&:blank?)
    end
  end
end
