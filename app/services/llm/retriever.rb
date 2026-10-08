# frozen_string_literal: true

module Llm
  # Turns a question into the most relevant document chunks using vector
  # similarity. This is the "retrieval" half of retrieval-augmented generation.
  #
  # The interface is deliberately tiny (one public method) so that swapping the
  # backing store from pgvector to Pinecone/Qdrant later touches only this class.
  class Retriever
    DEFAULT_TOP_K = 4

    def initialize(client: Llm::Client.new)
      @client = client
    end

    # Returns an Array of Chunk records most relevant to the question,
    # scoped to a single document.
    def relevant_chunks(document_id:, question:, top_k: DEFAULT_TOP_K)
      query_vector = @client.embed(question, input_type: "query")

      # pgvector cosine-distance search via the neighbor gem (or raw SQL).
      # `<=>` is pgvector's distance operator; smaller is closer.
      Chunk
        .where(document_id: document_id)
        .where.not(embedding: nil)
        .nearest_neighbors(:embedding, query_vector, distance: "cosine")
        .limit(top_k)
    end
  end
end
