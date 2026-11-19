# frozen_string_literal: true

module Llm
  module Evaluation
    # Turns per-question results into metrics. No database or API calls, so
    # any cutoff can be tried on recorded distances for free.
    #
    # Each result is a Hash with:
    #   :expect        "answer" or "refuse"
    #   :best_distance cosine distance of the closest passage (nil if none)
    #   :candidates    every passage the search considered, as
    #                  { document:, distance:, needed: } (Runner records these)
    #   :needs         answerable cases: the documents the answer needs
    #   :top_k         how many passages the app would keep
    #   :top_hit       one-passage cases: the needed passage ranked first
    #
    # With :candidates, the scorer replays Llm::Retriever.select_passages at
    # each cutoff, so it sees exactly which passages the app would keep.
    # Without them it falls back to :best_distance alone.
    class Scorer
      GRID = (30..90).step(5).map { |n| n / 100.0 }.freeze
      Candidate = Struct.new(:document_id, :neighbor_distance, :needed)

      def initialize(results)
        @results = results
      end

      def answerable = @results.select { |r| r[:expect] == "answer" }
      def unanswerable = @results.select { |r| r[:expect] == "refuse" }
      def cross_document = answerable.select { |r| Array(r[:needs]).size > 1 }
      def single_passage = answerable.reject { |r| r[:top_hit].nil? }

      # The passages the app would keep at this cutoff (nil = no cutoff).
      def self.selected(result, cutoff)
        candidates = result.fetch(:candidates).map { |c| Candidate.new(c[:document], c[:distance], c[:needed]) }
        Llm::Retriever.select_passages(candidates, top_k: result.fetch(:top_k), max_distance: cutoff)
      end

      # :correct, :false_refusal (refused, should answer), :incomplete
      # (answered without a document it needs), or :false_answer (answered,
      # should refuse).
      def self.outcome(result, cutoff)
        if result[:candidates]
          chosen = selected(result, cutoff)
          answered = chosen.any?
          complete = answered && (Array(result[:needs]) - chosen.map(&:document_id)).empty?
        else
          answered = complete = !result[:best_distance].nil? && (cutoff.nil? || result[:best_distance] <= cutoff)
        end

        if result[:expect] == "answer"
          return :correct if complete

          answered ? :incomplete : :false_refusal
        else
          answered ? :false_answer : :correct
        end
      end

      # Would the app answer at all (true) or refuse (false) at this cutoff?
      def self.answers?(result, cutoff)
        case outcome(result, cutoff)
        when :false_refusal then false
        when :correct then result[:expect] == "answer"
        else true
        end
      end

      # The smallest cutoff at which the app answers this question with every
      # document it needs: the farthest of those documents' closest passages.
      # For a question about one document, that is just its closest passage.
      def self.required_distance(result)
        needs = Array(result[:needs])
        return result[:best_distance] if result[:candidates].nil? || needs.empty?

        closest = needs.map { |key| result[:candidates].select { |c| c[:document] == key }.map { |c| c[:distance] }.min }
        closest.include?(nil) ? nil : closest.max
      end

      # The distance that decides each question: required_distance for
      # answerable ones, the closest passage for the rest.
      def self.deciding_distance(result)
        result[:expect] == "answer" ? required_distance(result) : result[:best_distance]
      end

      # Share of one-passage questions whose passage ranked first (nil if
      # there are none).
      def top1_accuracy
        single_passage.empty? ? nil : ratio(single_passage.count { |r| r[:top_hit] }, single_passage.size)
      end

      # When several documents are searched, share of one-document questions
      # whose closest passage came from the right document.
      def document_top1_accuracy
        cases = answerable.reject { |r| r[:top_document_hit].nil? }
        cases.empty? ? nil : ratio(cases.count { |r| r[:top_document_hit] }, cases.size)
      end

      def at(cutoff)
        outcomes = @results.map { |r| [r, self.class.outcome(r, cutoff)] }
        count = ->(kind) { outcomes.count { |_, o| o == kind } }
        correct_answers = outcomes.count { |r, o| r[:expect] == "answer" && o == :correct }
        correct_refusals = outcomes.count { |r, o| r[:expect] == "refuse" && o == :correct }

        {
          cutoff: cutoff,
          accuracy: ratio(correct_answers + correct_refusals, @results.size),
          answered_when_should: ratio(correct_answers, answerable.size),
          refused_when_should: ratio(correct_refusals, unanswerable.size),
          false_refusals: count.(:false_refusal),
          incomplete: count.(:incomplete),
          false_answers: count.(:false_answer)
        }
      end

      def sweep(grid = GRID)
        grid.map { |c| at(c) }
      end

      # The best cutoff, found from the recorded distances rather than a fixed
      # grid: every distinct deciding distance is a point where some question
      # flips, so only the midpoints between neighbouring points need trying.
      # Picks the best accuracy, then fewer wrong answers (a refusal is safer
      # than a made-up answer), then the widest gap, so small shifts in
      # distances are least likely to flip a decision. :margin is how far the
      # cutoff is from the nearest deciding distance.
      def recommended
        points = @results.filter_map { |r| self.class.deciding_distance(r) }.uniq.sort
        return at(GRID[GRID.size / 2]).merge(margin: nil) if points.empty?

        options = points.each_cons(2).map { |a, b| [midpoint(a, b), (b - a) / 2.0] }
        options << [(points.first - 0.01).round(3), 0.01] << [(points.last + 0.01).round(3), 0.01]

        options
          .map { |cutoff, margin| at(cutoff).merge(margin: margin.round(4)) }
          .max_by { |row| [row[:accuracy], -row[:false_answers], row[:margin]] }
      end

      # Is there a cutoff that gets every question right? Compares the
      # farthest answerable question (by required_distance) with the closest
      # unanswerable one.
      def separation
        needed = answerable.map { |r| self.class.required_distance(r) }
        closest = unanswerable.filter_map { |r| r[:best_distance] }.min
        return nil if needed.compact.empty? || closest.nil?

        farthest = needed.compact.max
        {
          farthest_answerable: farthest,
          closest_unanswerable: closest,
          clean: !needed.include?(nil) && farthest < closest,
          midpoint: midpoint(farthest, closest)
        }
      end

      # For questions that need several documents: did every one of them
      # contribute a passage, and was each document's needed passage kept?
      def coverage(cutoff)
        rows = cross_document.map do |r|
          chosen = self.class.selected(r, cutoff)
          contributed = chosen.map(&:document_id).uniq
          missing = Array(r[:needs]) - contributed
          passages_missing = Array(r[:needs]).reject { |key| chosen.any? { |c| c.document_id == key && c.needed } }
          { result: r, missing_documents: missing, missing_passages: passages_missing }
        end

        {
          questions: rows.size,
          all_documents: rows.count { |row| row[:missing_documents].empty? },
          all_passages: rows.count { |row| row[:missing_passages].empty? },
          misses: rows.reject { |row| row[:missing_documents].empty? && row[:missing_passages].empty? }
        }
      end

      private

      # Rounded for a tidy setting, unless rounding would land on or past
      # one of the two distances.
      def midpoint(a, b)
        exact = (a + b) / 2.0
        rounded = exact.round(3)
        rounded > a && rounded < b ? rounded : exact.round(6)
      end

      def ratio(part, whole)
        whole.zero? ? 0.0 : (part.to_f / whole).round(3)
      end
    end
  end
end