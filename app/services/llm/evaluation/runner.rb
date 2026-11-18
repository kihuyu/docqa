# frozen_string_literal: true

require "yaml"

module Llm
  module Evaluation
    # Runs an evaluation file (see eval/returns_policy.yml) against the real
    # retriever and model:
    #
    #   1. adds the file's document to the database and embeds it
    #   2. retrieves passages for each question with NO cutoff, recording the
    #      ranked passages and their distances (one embedding call each)
    #   3. optionally (answers: true) asks the full pipeline each question and
    #      checks the answer (one chat call each)
    #   4. deletes the document again
    #
    # Because step 2 records distances without a cutoff, Scorer can then try
    # every cutoff on them with no further API calls.
    class Runner
      # Phrases that mean the model declined even though passages were found.
      # Deliberately tied to the source ("the document doesn't say"), so a real
      # answer like "you don't have to pay return shipping" isn't counted.
      MODEL_REFUSAL = /
        (n't|not)\s+have\s+enough\s+information
        | not\s+enough\s+information
        | no\s+information\s+(about|on|regarding)
        | (document|policy|text|context|passages?|information\s+provided)[^.]{0,60}?
          \b(don't|doesn't|do\s+not|does\s+not)\s+(say|mention|specify|state|cover|address|provide)
        | not\s+(mentioned|specified|stated|addressed)\s+in
      /ix

      attr_reader :results

      def initialize(path:, answers: false, pause: 6.0,
                     retriever: Llm::Retriever.new, answerer: nil, logger: Rails.logger)
        @path = path.to_s
        @answers = answers
        @pause = pause
        @retriever = retriever
        @answerer = answerer
        @logger = logger
      end

      # Returns the per-question results (Array of Hashes).
      def run
        data = YAML.safe_load_file(@path)
        document = build_document(data.fetch("document"))
        cases = data.fetch("cases")

        @results = cases.each_with_index.map do |c, i|
          sleep(@pause) if @answers && i.positive? && @pause.positive?
          evaluate(c, document)
        end
      ensure
        document&.destroy
      end

      private

      def build_document(spec)
        document = Document.create!(title: "[eval] #{spec.fetch('title')}",
                                    content: spec.fetch("content"), status: "processing")
        Llm::Ingestor.new.send(:chunks_for, document.content).each do |text|
          document.chunks.create!(content: text)
        end
        # Embed right here rather than through the queue: errors surface
        # immediately, and no running worker is needed.
        EmbedChunksJob.new.perform(document.id)
        document.reload
      end

      def evaluate(spec, document)
        question = spec.fetch("question")
        expect = spec.fetch("expect")
        phrase = spec["passage"]

        ranked = @retriever.relevant_chunks(document_id: document.id, question: question, max_distance: nil)
        best = ranked.first
        hit_index = phrase && ranked.index { |chunk| chunk.content.include?(phrase) }

        result = {
          question: question,
          expect: expect,
          kind: spec["kind"],
          best_distance: best&.neighbor_distance&.to_f&.round(4),
          distances: ranked.map { |chunk| chunk.neighbor_distance.to_f.round(4) },
          top_hit: expect == "answer" ? hit_index == 0 : nil,
          hit_rank: hit_index&.+(1)
        }
        result.merge!(check_answer(spec, document)) if @answers
        result
      end

      def check_answer(spec, document)
        reply = answerer.call(document_id: document.id, question: spec.fetch("question")).to_h
        answer = reply[:answer].to_s
        refused = Array(reply[:sources]).empty? || answer.match?(MODEL_REFUSAL)

        ok = if spec["expect"] == "answer"
          words = Array(spec["answer_includes_any"])
          !refused && (words.empty? || words.any? { |w| answer.downcase.include?(w.downcase) })
        else
          refused
        end

        { model_answer: answer, model_refused: refused, answer_ok: ok }
      rescue Llm::Client::Error => e
        { model_answer: "ERROR: #{e.message}", model_refused: nil, answer_ok: false }
      end

      def answerer
        @answerer ||= Llm::Answerer.new
      end
    end
  end
end
