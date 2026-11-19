# frozen_string_literal: true

module Llm
  # The "generation" half of RAG: take retrieved passages, build a grounded
  # prompt, ask the model, and return the answer with its sources.
  #
  # The prompt tells the model to answer ONLY from the passages and to say when
  # the answer isn't there, which is what keeps it from making things up.
  # Works for one document or several; with several, each passage is labelled
  # with its document's title so the answer can say where each part came from.
  class Answerer
    NOT_ENOUGH_INFORMATION = "I don't have enough information to answer that from the provided documents."

    class Result
      attr_reader :answer, :sources, :tokens_used

      def initialize(answer:, sources:, tokens_used:)
        @answer = answer
        @sources = sources
        @tokens_used = tokens_used
      end

      def to_h
        {
          answer: answer,
          # `text` is the full passage, so a client can locate and highlight it
          # in its document; `excerpt` is a short preview.
          sources: sources.map do |c|
            {
              chunk_id: c.id,
              document_id: c.document_id,
              document_title: c.document.title,
              excerpt: c.content.truncate(200),
              text: c.content
            }
          end,
          tokens_used: tokens_used
        }
      end
    end

    SYSTEM_PROMPT = <<~PROMPT
      You are a precise assistant. Answer the user's question using ONLY the
      passages provided. Each passage is labelled with the title of the
      document it comes from.

      - If the answer is not contained in the passages, say exactly:
        "#{NOT_ENOUGH_INFORMATION}"
      - When the answer uses more than one document, say which document each
        part comes from.
      - If documents disagree, say so and give each one's version rather than
        choosing between them.
      - Do not use outside knowledge. Be concise.
    PROMPT

    def initialize(client: Llm::Client.new, retriever: Llm::Retriever.new)
      @client = client
      @retriever = retriever
    end

    # Pass document_id: for one document or document_ids: for several.
    def call(question:, document_id: nil, document_ids: nil)
      chunks = @retriever.relevant_chunks(document_id: document_id, document_ids: document_ids, question: question)

      return Result.new(answer: NOT_ENOUGH_INFORMATION, sources: [], tokens_used: 0) if chunks.empty?

      response = @client.chat_with_usage(
        system: SYSTEM_PROMPT,
        user: user_prompt(question, build_context(chunks))
      )

      Result.new(answer: response[:text], sources: chunks, tokens_used: response[:tokens_used])
    end

    private

    def build_context(chunks)
      chunks.map.with_index(1) do |chunk, i|
        %([#{i}] From "#{chunk.document.title}":\n#{chunk.content})
      end.join("\n\n")
    end

    def user_prompt(question, context)
      <<~PROMPT
        Passages:
        #{context}

        Question: #{question}
      PROMPT
    end
  end
end