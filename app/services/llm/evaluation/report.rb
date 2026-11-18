# frozen_string_literal: true

module Llm
  module Evaluation
    # Formats evaluation results as plain text for the terminal.
    class Report
      def initialize(results, current_cutoff:)
        @results = results
        @cutoff = current_cutoff
        @scorer = Scorer.new(results)
      end

      def to_s
        [retrieval, per_question, sweep, separation, recommendation, answers].compact.join("\n\n")
      end

      # Headline numbers, for saving or failing a build on.
      def summary
        now = @scorer.at(@cutoff)
        best = @scorer.recommended
        {
          questions: @results.size,
          top1_accuracy: @scorer.top1_accuracy,
          current_cutoff: @cutoff,
          accuracy: now[:accuracy],
          false_answers: now[:false_answers],
          false_refusals: now[:false_refusals],
          recommended_cutoff: best[:cutoff],
          recommended_accuracy: best[:accuracy],
          answer_accuracy: answer_accuracy
        }.compact
      end

      private

      def retrieval
        answerable = @scorer.answerable
        hits = answerable.count { |r| r[:top_hit] }
        lines = ["Retrieval: right passage ranked first for #{hits} of #{answerable.size} answerable questions " \
                 "(#{pct(@scorer.top1_accuracy)})"]
        answerable.reject { |r| r[:top_hit] }.each do |r|
          where = r[:hit_rank] ? "ranked ##{r[:hit_rank]}" : "not retrieved"
          lines << "  missed: #{r[:question]} (right passage #{where})"
        end
        lines.join("\n")
      end

      def per_question
        lines = ["Per question, at the current cutoff (#{fmt_cutoff(@cutoff)}):",
                 "       distance  expected  question"]
        @results.sort_by { |r| r[:best_distance] || Float::INFINITY }.each do |r|
          answered = Scorer.answers?(r, @cutoff)
          correct = (r[:expect] == "answer") == answered
          note = if correct then ""
                 elsif answered then "  <- answered, should refuse"
                 else "  <- refused, should answer"
                 end
          kind = r[:kind] == "in_domain" ? " (same topic)" : ""
          lines << format("  %s   %-8s  %-8s  %s%s%s", correct ? "ok " : "BAD", fmt_dist(r[:best_distance]),
                          r[:expect], r[:question], kind, note)
        end
        lines.join("\n")
      end

      def sweep
        recommended = @scorer.recommended[:cutoff]
        lines = ["Trying every cutoff (no extra API calls):",
                 "  cutoff  correct  answered when it should  refused when it should"]
        @scorer.sweep.each do |row|
          marks = []
          marks << "current" if @cutoff && (row[:cutoff] - @cutoff).abs < 1e-9
          marks << "recommended" if row[:cutoff] == recommended
          lines << format("  %-6s  %-7s  %-23s  %-22s %s", fmt_cutoff(row[:cutoff]), pct(row[:accuracy]),
                          pct(row[:answered_when_should]), pct(row[:refused_when_should]),
                          marks.empty? ? "" : "<- #{marks.join(', ')}").rstrip
        end
        lines.join("\n")
      end

      def separation
        s = @scorer.separation or return nil
        if s[:clean]
          "The groups separate cleanly: the farthest answerable question is at #{fmt_dist(s[:farthest_answerable])}, " \
            "the closest unanswerable one at #{fmt_dist(s[:closest_unanswerable])}. " \
            "Any cutoff between them is perfect; the midpoint is #{s[:midpoint]}."
        else
          "The groups overlap: the farthest answerable question is at #{fmt_dist(s[:farthest_answerable])}, " \
            "but an unanswerable one is already at #{fmt_dist(s[:closest_unanswerable])}. " \
            "No cutoff gets every question right; see the BAD lines above."
        end
      end

      def recommendation
        best = @scorer.recommended
        now = @scorer.at(@cutoff)
        if @cutoff && (best[:cutoff] - @cutoff).abs < 1e-9
          "Recommendation: keep the current cutoff (#{fmt_cutoff(@cutoff)}), #{pct(now[:accuracy])} correct."
        elsif best[:accuracy] == now[:accuracy]
          "Recommendation: set retrieval.max_distance to #{fmt_cutoff(best[:cutoff])}. Same share correct " \
            "(#{pct(now[:accuracy])}) as the current #{fmt_cutoff(@cutoff)}, but #{best[:false_answers]} wrong " \
            "answer(s) instead of #{now[:false_answers]}: it refuses where it would otherwise answer without support."
        else
          "Recommendation: set retrieval.max_distance to #{fmt_cutoff(best[:cutoff])} " \
            "(#{pct(best[:accuracy])} correct, vs #{pct(now[:accuracy])} at the current #{fmt_cutoff(@cutoff)})."
        end
      end

      def answers
        checked = @results.reject { |r| r[:answer_ok].nil? }
        return nil if checked.empty?

        lines = ["Answers from the model (whole pipeline, current cutoff): " \
                 "#{checked.count { |r| r[:answer_ok] }} of #{checked.size} as expected (#{pct(answer_accuracy)})"]
        checked.reject { |r| r[:answer_ok] }.each do |r|
          lines << "  #{r[:question]}  [expected #{r[:expect]}]"
          lines << "    -> #{r[:model_answer].to_s.gsub(/\s+/, ' ')[0, 200]}"
        end
        lines.join("\n")
      end

      def answer_accuracy
        checked = @results.reject { |r| r[:answer_ok].nil? }
        return nil if checked.empty?

        (checked.count { |r| r[:answer_ok] }.to_f / checked.size).round(3)
      end

      def pct(x) = "#{(x * 100).round}%"
      def fmt_dist(d) = d.nil? ? "none" : format("%.3f", d)
      def fmt_cutoff(c) = c.nil? ? "off" : format("%.2f", c)
    end
  end
end
