# frozen_string_literal: true

module Llm
  # The "generation" half of RAG: take retrieved chunks, build a grounded
  # prompt, ask the model, and return the answer with its sources.
  #
  # Key behaviour: the prompt instructs the model to answer ONLY from the
  # provided context and to say when the answer is not present. This is what
  # keeps it from hallucinating.
  class Answerer
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
          sources: sources.map { |c| { chunk_id: c.id, excerpt: c.content.truncate(200) } },
          tokens_used: tokens_used
        }
      end
    end

    SYSTEM_PROMPT = <<~PROMPT
      You are a precise assistant. Answer the user's question using ONLY the
      context provided. If the answer is not contained in the context, say
      "I don't have enough information to answer that from the provided
      documents." Do not use outside knowledge. Be concise.
    PROMPT

    def initialize(client: Llm::Client.new, retriever: Llm::Retriever.new)
      @client = client
      @retriever = retriever
    end

    def call(document_id:, question:)
      chunks = @retriever.relevant_chunks(document_id: document_id, question: question)

      if chunks.empty?
        return Result.new(
          answer: "I don't have enough information to answer that from the provided documents.",
          sources: [],
          tokens_used: 0
        )
      end

      context = build_context(chunks)
      response = @client.chat_with_usage(
        system: SYSTEM_PROMPT,
        user: user_prompt(question, context)
      )

      Result.new(answer: response[:text], sources: chunks, tokens_used: response[:tokens_used])
    end

    private

    def build_context(chunks)
      chunks.map.with_index(1) do |chunk, i|
        "[#{i}] #{chunk.content}"
      end.join("\n\n")
    end

    def user_prompt(question, context)
      <<~PROMPT
        Context:
        #{context}

        Question: #{question}
      PROMPT
    end
  end
end
