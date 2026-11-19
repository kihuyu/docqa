# frozen_string_literal: true

module Llm
  # Turns a question into the most relevant passages using vector similarity.
  # This is the "retrieval" half of retrieval-augmented generation.
  #
  # Searches one document or several. The interface is deliberately tiny (one
  # public method) so that swapping pgvector for Pinecone/Qdrant later touches
  # only this class.
  class Retriever
    DEFAULT_TOP_K = 4
    # Searching several documents at once returns a few more passages, so each
    # document has room to contribute.
    MULTI_DOCUMENT_TOP_K = AppSetting.integer(:retrieval, :multi_document_top_k, default: 6)

    # Nearest-neighbour search always returns *something*, even for a question
    # the document has nothing to do with. Passages farther than this cosine
    # distance (0 = same meaning, 1 = unrelated) are dropped, so an off-topic
    # question retrieves nothing and the answerer refuses without calling the
    # model. Choose it with `bin/rails eval:run`; false turns the cutoff off.
    MAX_DISTANCE = AppSetting.optional(:retrieval, :max_distance, env: "RETRIEVAL_MAX_DISTANCE",
                                       default: 0.6) { |v| Float(v) }

    def initialize(client: Llm::Client.new, logger: Rails.logger)
      @client = client
      @logger = logger
    end

    # Returns an Array of Chunk records relevant to the question, closest
    # first, each with #neighbor_distance and its document preloaded. May be
    # empty. Pass document_id: for one document or document_ids: for several.
    def relevant_chunks(question:, document_id: nil, document_ids: nil, top_k: nil, max_distance: MAX_DISTANCE)
      ids = Array(document_ids || document_id).map(&:to_i).uniq
      raise ArgumentError, "pass document_id: or document_ids:" if ids.empty?

      top_k ||= ids.size > 1 ? MULTI_DOCUMENT_TOP_K : DEFAULT_TOP_K
      query_vector = @client.embed(question, input_type: "query")

      # One query per document, so every document's closest passages are
      # considered, rather than whichever document dominates a single query.
      candidates = ids.flat_map { |id| nearest_in(id, query_vector, top_k) }

      selected = select_passages(candidates, top_k: top_k, max_distance: max_distance)
      @logger.info("[Llm::Retriever] documents=#{ids.join(',')} kept=#{selected.size}/#{candidates.size} " \
                     "distances=#{candidates.map { |c| c.neighbor_distance.round(3) }.sort.join(',')}")
      selected
    end

    private

    def nearest_in(document_id, query_vector, limit)
      Chunk
        .where(document_id: document_id)
        .where.not(embedding: nil)
        .nearest_neighbors(:embedding, query_vector, distance: "cosine")
        .limit(limit)
        .preload(:document)
        .to_a
    end

    # Keeps passages within the cutoff, then picks up to top_k of them. Each
    # document's best passage is guaranteed a place, so a question comparing
    # two documents isn't answered from only one of them; the remaining slots
    # go to the closest passages overall.
    def select_passages(candidates, top_k:, max_distance:)
      kept = candidates
               .select { |c| max_distance.nil? || c.neighbor_distance <= max_distance }
               .sort_by(&:neighbor_distance)

      best_per_document = kept.group_by(&:document_id).values.map(&:first)
      chosen = best_per_document.first(top_k)
      (kept - chosen).each do |chunk|
        break if chosen.size >= top_k

        chosen << chunk
      end
      chosen.sort_by(&:neighbor_distance)
    end
  end
end