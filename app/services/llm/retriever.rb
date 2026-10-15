# frozen_string_literal: true

module Llm
  # Turns a question into the most relevant document chunks using vector
  # similarity. This is the "retrieval" half of retrieval-augmented generation.
  #
  # The interface is deliberately tiny (one public method) so that swapping the
  # backing store from pgvector to Pinecone/Qdrant later touches only this class.
  class Retriever
    DEFAULT_TOP_K = 4

    # Nearest-neighbour search always returns *something*, even for a question
    # the document has nothing to do with. Chunks farther than this cosine
    # distance (0 = same meaning, 1 = unrelated) are dropped, so an off-topic
    # question retrieves nothing and the answerer refuses without calling the
    # model. Tune retrieval.max_distance in credentials using the distances
    # logged below; set it to false to turn the cutoff off.
    MAX_DISTANCE = AppSetting.optional(:retrieval, :max_distance, env: "RETRIEVAL_MAX_DISTANCE",
                                       default: 0.6) { |v| Float(v) }

    def initialize(client: Llm::Client.new, logger: Rails.logger)
      @client = client
      @logger = logger
    end

    # Returns an Array of Chunk records most relevant to the question, scoped
    # to a single document, closest first. May be empty.
    def relevant_chunks(document_id:, question:, top_k: DEFAULT_TOP_K, max_distance: MAX_DISTANCE)
      query_vector = @client.embed(question, input_type: "query")

      # pgvector cosine-distance search via the neighbor gem. Each returned
      # record carries its distance in #neighbor_distance; smaller is closer.
      candidates = Chunk
                     .where(document_id: document_id)
                     .where.not(embedding: nil)
                     .nearest_neighbors(:embedding, query_vector, distance: "cosine")
                     .limit(top_k)
                     .to_a

      kept = within_distance(candidates, max_distance)
      @logger.info("[Llm::Retriever] document=#{document_id} kept=#{kept.size}/#{candidates.size} " \
                     "distances=#{candidates.map { |c| c.neighbor_distance.round(3) }.join(',')}")
      kept
    end

    private

    def within_distance(chunks, max_distance)
      return chunks if max_distance.nil?

      chunks.select { |chunk| chunk.neighbor_distance <= max_distance }
    end
  end
end
