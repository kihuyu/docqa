# frozen_string_literal: true

module Llm
  module Evaluation
    # Turns per-question results into metrics. Pure Ruby with no database or
    # API calls, so any cutoff can be tried on recorded distances for free.
    #
    # Each result is a Hash with:
    #   :expect        "answer" or "refuse"
    #   :best_distance cosine distance of the top-ranked passage (nil if none)
    #   :top_hit       answerable cases: top passage contains the expected phrase
    class Scorer
      GRID = (30..90).step(5).map { |n| n / 100.0 }.freeze

      def initialize(results)
        @results = results
      end

      def answerable = @results.select { |r| r[:expect] == "answer" }
      def unanswerable = @results.select { |r| r[:expect] == "refuse" }

      # Would the app answer (true) or refuse (false) at this cutoff?
      # nil cutoff = no cutoff: answers whenever anything was retrieved.
      def self.answers?(result, cutoff)
        return false if result[:best_distance].nil?

        cutoff.nil? || result[:best_distance] <= cutoff
      end

      # Share of answerable questions whose best passage ranked first.
      def top1_accuracy
        ratio(answerable.count { |r| r[:top_hit] }, answerable.size)
      end

      def at(cutoff)
        false_refusals = answerable.count { |r| !self.class.answers?(r, cutoff) }
        false_answers = unanswerable.count { |r| self.class.answers?(r, cutoff) }
        correct = @results.size - false_refusals - false_answers

        {
          cutoff: cutoff,
          accuracy: ratio(correct, @results.size),
          answered_when_should: ratio(answerable.size - false_refusals, answerable.size),
          refused_when_should: ratio(unanswerable.size - false_answers, unanswerable.size),
          false_refusals: false_refusals,
          false_answers: false_answers
        }
      end

      def sweep(grid = GRID)
        grid.map { |c| at(c) }
      end

      # The cutoff with the best accuracy, preferring fewer wrong answers on a
      # tie (a refusal is safer than a made-up answer), then the middle of the
      # tied range so small shifts in distances don't flip decisions.
      def recommended(grid = GRID)
        rows = sweep(grid)
        best = rows.max_by { |r| [r[:accuracy], -r[:false_answers]] }
        ties = rows.select { |r| r[:accuracy] == best[:accuracy] && r[:false_answers] == best[:false_answers] }
        ties[ties.size / 2]
      end

      # Is there a cutoff that separates the two groups perfectly?
      # Compares the farthest answerable question with the closest
      # unanswerable one.
      def separation
        worst_answerable = answerable.filter_map { |r| r[:best_distance] }.max
        best_unanswerable = unanswerable.filter_map { |r| r[:best_distance] }.min
        return nil if worst_answerable.nil? || best_unanswerable.nil?

        {
          farthest_answerable: worst_answerable,
          closest_unanswerable: best_unanswerable,
          clean: worst_answerable < best_unanswerable,
          midpoint: ((worst_answerable + best_unanswerable) / 2.0).round(3)
        }
      end

      private

      def ratio(part, whole)
        whole.zero? ? 0.0 : (part.to_f / whole).round(3)
      end
    end
  end
end
