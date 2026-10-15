# frozen_string_literal: true

module Llm
  # Splits a document into overlapping chunks and enqueues background embedding.
  # Returns immediately; embedding happens in EmbedChunksJob.
  class Ingestor
    CHUNK_SIZE = 800    # characters; simple and good enough for an MVP
    OVERLAP    = 100    # keep some context across chunk boundaries

    def call(title:, content:)
      # All-or-nothing: a failure part-way through never leaves a document with
      # half its chunks saved.
      document = Document.transaction do
        doc = Document.create!(title: title, content: content, status: "processing")
        chunks_for(content).each { |text| doc.chunks.create!(content: text) }
        doc
      end

      # Enqueue only after the rows are committed, so the job can always see them.
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
