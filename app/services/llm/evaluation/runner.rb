# frozen_string_literal: true

require "yaml"

module Llm
  module Evaluation
    # Runs an evaluation file (see eval/*.yml) against the real retriever and
    # model:
    #
    #   1. adds the file's documents to the database and embeds them
    #   2. for each question, records every passage the search considers
    #      (before the cutoff), with its document and distance: one embedding
    #      call per question
    #   3. optionally (answers: true) asks the full pipeline each question and
    #      checks the answer: one chat call per question
    #   4. deletes the documents again
    #
    # Because step 2 records distances before the cutoff, Scorer can replay
    # the retriever's selection at any cutoff with no further API calls.
    #
    # A file has either `document:` (one document; cases use `passage:`) or
    # `documents:` (several, keyed by a short name; cases use `passages:`,
    # one phrase per document the answer needs, and may limit the search
    # with `search:`). See eval/returns_policy.yml and eval/northwind_policies.yml.
    class Runner
      class InvalidFile < StandardError; end

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

      attr_reader :results, :documents

      def initialize(path:, answers: false, pause: 6.0,
                     retriever: Llm::Retriever.new, answerer: nil, logger: Rails.logger)
        @path = path.to_s
        @answers = answers
        @pause = pause
        @retriever = retriever
        @answerer = answerer
        @logger = logger
      end

      # Returns the per-question results (Array of Hashes). Afterwards
      # #documents describes what was searched: { key => { title:, passages: } }.
      def run
        data = YAML.safe_load_file(@path)
        specs = document_specs(data)
        cases = data.fetch("cases").map { |c| normalize_case(c, specs.keys) }

        records = {}
        specs.each { |key, spec| records[key] = build_document(spec) }
        check_phrases!(cases, records)
        records.each_value { |doc| embed(doc) }
        @documents = records.transform_values { |doc| { title: doc.title.delete_prefix("[eval] "), passages: doc.chunks.size } }
        @key_for = records.to_h { |key, doc| [doc.id, key] }

        @results = cases.each_with_index.map do |c, i|
          sleep(@pause) if @answers && i.positive? && @pause.positive?
          evaluate(c, records)
        end
      ensure
        records&.each_value(&:destroy)
      end

      private

      def document_specs(data)
        if data.key?("documents")
          data.fetch("documents").to_h { |key, spec| [key.to_s, spec] }
        else
          { "document" => data.fetch("document") }
        end
      end

      # Turns a case into { question:, expect:, kind:, search: [keys], needs: { key => phrase }, ... }.
      def normalize_case(raw, keys)
        question = raw.fetch("question")
        search = Array(raw["search"] || keys).map(&:to_s)
        needs = (raw["passages"] || {}).to_h { |key, phrase| [key.to_s, phrase] }
        if raw["passage"]
          invalid!(question, "use `passages:` to say which document `passage:` is in") if search.size > 1
          needs[search.first] = raw["passage"]
        end

        unknown = (search + needs.keys) - keys
        invalid!(question, "unknown document(s): #{unknown.join(', ')}") if unknown.any?
        invalid!(question, "`passages:` names a document that isn't searched") if (needs.keys - search).any?

        {
          question: question,
          expect: raw.fetch("expect"),
          kind: raw["kind"],
          search: search,
          needs: raw.fetch("expect") == "answer" ? needs : {},
          answer_groups: answer_groups(raw)
        }
      end

      # answer_includes_any: ["a", "b"]         -> one group: any of them
      # answer_includes_each: [["a", "b"], "c"] -> every group, any word within it
      def answer_groups(raw)
        if raw["answer_includes_each"]
          Array(raw["answer_includes_each"]).map { |group| Array(group) }
        elsif raw["answer_includes_any"]
          [Array(raw["answer_includes_any"])]
        else
          []
        end
      end

      def invalid!(question, problem)
        raise InvalidFile, "#{@path}: #{question.inspect}: #{problem}"
      end

      def build_document(spec)
        document = Document.create!(title: "[eval] #{spec.fetch('title')}",
                                    content: spec.fetch("content"), status: "processing")
        Llm::Ingestor.new.send(:chunks_for, document.content).each do |text|
          document.chunks.create!(content: text)
        end
        document
      end

      # Embed right here rather than through the queue: errors surface
      # immediately, and no running worker is needed.
      def embed(document)
        EmbedChunksJob.new.perform(document.id)
        document.reload
      end

      # A phrase that no passage contains (a typo, or one split across two
      # passages) would quietly count as a miss on every run, so stop before
      # spending any API calls.
      def check_phrases!(cases, records)
        cases.each do |c|
          c[:needs].each do |key, phrase|
            next if records.fetch(key).chunks.any? { |chunk| chunk.content.include?(phrase) }

            invalid!(c[:question], "no passage of #{key} contains #{phrase.inspect}")
          end
        end
      end

      def evaluate(spec, records)
        ids = spec[:search].map { |key| records.fetch(key).id }
        found = @retriever.candidates(question: spec[:question], document_ids: ids)
                          .sort_by(&:neighbor_distance)

        candidates = found.map do |chunk|
          key = @key_for.fetch(chunk.document_id)
          phrase = spec[:needs][key]
          { document: key, distance: chunk.neighbor_distance.to_f.round(4),
            needed: phrase ? chunk.content.include?(phrase) : false }
        end

        result = {
          question: spec[:question],
          expect: spec[:expect],
          kind: spec[:kind],
          search: spec[:search],
          needs: spec[:needs].keys,
          top_k: Llm::Retriever.top_k_for(ids.size),
          candidates: candidates,
          best_distance: candidates.first&.fetch(:distance),
          distances: candidates.map { |c| c[:distance] }
        }
        result.merge!(single_passage_ranking(spec, candidates)) if spec[:needs].size == 1
        result.merge!(check_answer(spec, ids)) if @answers
        result
      end

      # For a question answered by one passage: did it rank first?
      def single_passage_ranking(spec, candidates)
        hit_index = candidates.index { |c| c[:needed] }
        {
          top_hit: hit_index == 0,
          hit_rank: hit_index&.+(1),
          top_document_hit: spec[:search].size > 1 ? candidates.first&.fetch(:document) == spec[:needs].keys.first : nil
        }
      end

      def check_answer(spec, ids)
        reply = answerer.call(document_ids: ids, question: spec[:question]).to_h
        answer = reply[:answer].to_s
        refused = Array(reply[:sources]).empty? || answer.match?(MODEL_REFUSAL)

        ok = if spec[:expect] == "answer"
               text = answer.downcase
               !refused && spec[:answer_groups].all? { |group| group.any? { |w| text.include?(w.downcase) } }
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