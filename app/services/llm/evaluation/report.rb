# frozen_string_literal: true

module Llm
  module Evaluation
    # Formats evaluation results as plain text for the terminal.
    class Report
      attr_reader :results

      # documents: { key => { title:, passages: } } from Runner#documents.
      def initialize(results, current_cutoff:, documents: nil, name: nil)
        @results = results
        @cutoff = current_cutoff
        @documents = documents
        @name = name
        @scorer = Scorer.new(results)
      end

      # One line per file plus the single best cutoff across all of them,
      # since the app has only one setting. reports: Array of Report.
      def self.overall(reports, current_cutoff:)
        all = Scorer.new(reports.flat_map(&:results))
        now = all.at(current_cutoff)
        best = all.recommended
        lines = ["All files together (#{reports.sum { |r| r.summary[:questions] }} questions):"]
        reports.each do |r|
          s = r.summary
          lines << format("  %-28s %s correct at %s; best on its own %s (%s)", s[:name], pct(s[:accuracy]),
                          fmt_cutoff(current_cutoff), fmt_cutoff(s[:recommended_cutoff]), pct(s[:recommended_accuracy]))
        end
        lines << "  Current cutoff #{fmt_cutoff(current_cutoff)}: #{pct(now[:accuracy])} correct overall " \
          "(#{now[:false_answers]} wrong answers, #{now[:false_refusals]} wrong refusals, " \
          "#{now[:incomplete]} incomplete)."
        lines << if best[:accuracy] > now[:accuracy] || best[:false_answers] < now[:false_answers]
                   "  Best single cutoff: #{fmt_cutoff(best[:cutoff])}, #{pct(best[:accuracy])} correct overall " \
                     "(#{best[:false_answers]} wrong answers, #{best[:false_refusals]} wrong refusals, #{best[:incomplete]} incomplete)."
                 else
                   "  The current cutoff is already the best single setting for these files."
                 end
        lines.join("\n")
      end

      def to_s
        [header, retrieval, cross_document, per_question, sweep, separation, recommendation, answers]
          .compact.join("\n\n")
      end

      # Headline numbers, for saving or failing a build on.
      def summary
        now = @scorer.at(@cutoff)
        best = @scorer.recommended
        coverage = @scorer.coverage(@cutoff)
        {
          name: @name,
          documents: @documents&.size,
          passages: @documents&.sum { |_, d| d[:passages] },
          questions: @results.size,
          top1_accuracy: @scorer.top1_accuracy,
          document_top1_accuracy: @scorer.document_top1_accuracy,
          current_cutoff: @cutoff,
          accuracy: now[:accuracy],
          false_answers: now[:false_answers],
          false_refusals: now[:false_refusals],
          incomplete: now[:incomplete],
          cross_document_questions: coverage[:questions].positive? ? coverage[:questions] : nil,
          cross_document_all_documents: coverage[:questions].positive? ? coverage[:all_documents] : nil,
          cross_document_all_passages: coverage[:questions].positive? ? coverage[:all_passages] : nil,
          recommended_cutoff: best[:cutoff],
          recommended_accuracy: best[:accuracy],
          answer_accuracy: answer_accuracy
        }.compact
      end

      private

      def header
        return nil unless @documents

        docs = @documents.values.map { |d| "#{d[:title]} (#{d[:passages]} #{d[:passages] == 1 ? 'passage' : 'passages'})" }
        "#{@name || 'Evaluation'}: #{@results.size} questions over #{docs.join(', ')}"
      end

      def retrieval
        cases = @scorer.single_passage
        return nil if cases.empty?

        hits = cases.count { |r| r[:top_hit] }
        lines = ["Retrieval: right passage ranked first for #{hits} of #{cases.size} questions answered by one passage " \
                   "(#{pct(@scorer.top1_accuracy)})"]
        if (doc_top1 = @scorer.document_top1_accuracy)
          lines << "  closest passage came from the right document: #{pct(doc_top1)}"
        end
        cases.reject { |r| r[:top_hit] }.each do |r|
          where = r[:hit_rank] ? "ranked ##{r[:hit_rank]}" : "not retrieved"
          lines << "  missed: #{r[:question]} (right passage #{where})"
        end
        lines.join("\n")
      end

      def cross_document
        c = @scorer.coverage(@cutoff)
        return nil if c[:questions].zero?

        lines = ["Questions that need several documents, at the current cutoff (#{fmt_cutoff(@cutoff)}):",
                 "  every needed document contributed a passage: #{c[:all_documents]} of #{c[:questions]}",
                 "  every needed passage was kept:               #{c[:all_passages]} of #{c[:questions]}"]
        c[:misses].each do |miss|
          r = miss[:result]
          closest = Array(r[:needs]).map { |key| "#{title(key)} #{fmt_dist(closest_in(r, key))}" }.join(", ")
          gaps = if miss[:missing_documents].sort == Array(r[:needs]).sort && Scorer.selected(r, @cutoff).empty?
                   ["refused, nothing within the cutoff (closest: #{closest})"]
                 else
                   miss[:missing_documents].map { |key| "nothing from #{title(key)} (closest #{fmt_dist(closest_in(r, key))})" } +
                     (miss[:missing_passages] - miss[:missing_documents]).map { |key| "a different #{title(key)} passage than expected" }
                 end
          lines << "  #{r[:question]}"
          lines << "    -> #{gaps.join('; ')}"
        end
        lines.join("\n")
      end

      def per_question
        several = @scorer.cross_document.any?
        lines = ["Per question, at the current cutoff (#{fmt_cutoff(@cutoff)}):"]
        if several
          lines << "  (distance: for a question that needs several documents, the farthest of those documents' " \
            "closest passages)"
        end
        lines << "       distance  expected  question"
        @results.sort_by { |r| Scorer.deciding_distance(r) || Float::INFINITY }.each do |r|
          outcome = Scorer.outcome(r, @cutoff)
          note = { false_answer: "  <- answered, should refuse", false_refusal: "  <- refused, should answer",
                   incomplete: "  <- answered without #{missing_titles(r)}" }.fetch(outcome, "")
          tag = if r[:kind] == "in_domain" then " (same topic)"
                elsif Array(r[:needs]).size > 1 then " (#{Array(r[:needs]).size} documents)"
                else ""
                end
          lines << format("  %s   %-8s  %-8s  %s%s%s", outcome == :correct ? "ok " : "BAD",
                          fmt_dist(Scorer.deciding_distance(r)), r[:expect], r[:question], tag, note)
        end
        lines.join("\n")
      end

      def sweep
        recommended = @scorer.recommended[:cutoff]
        several = @scorer.cross_document.any?
        cutoffs = (Scorer::GRID + [@cutoff, recommended]).compact.uniq.sort
        lines = ["Trying cutoffs (no extra API calls):",
                 "  cutoff  correct  answered when it should  refused when it should#{'  incomplete' if several}"]
        cutoffs.each do |cutoff|
          row = @scorer.at(cutoff)
          marks = []
          marks << "current" if @cutoff && (cutoff - @cutoff).abs < 1e-9
          marks << "recommended" if (cutoff - recommended).abs < 1e-9
          extra = several ? format("  %-10s", row[:incomplete]) : ""
          lines << format("  %-6s  %-7s  %-23s  %-22s%s %s", fmt_cutoff(cutoff), pct(row[:accuracy]),
                          pct(row[:answered_when_should]), pct(row[:refused_when_should]), extra,
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
        margin = if best[:margin].nil? then ""
                 elsif best[:margin] < 0.001 then " Questions sit less than 0.001 either side of it, so treat it as fragile."
                 else " The nearest question is #{fmt_dist(best[:margin])} away from it."
                 end

        if now[:accuracy] >= best[:accuracy] && now[:false_answers] <= best[:false_answers]
          "Recommendation: keep the current cutoff (#{fmt_cutoff(@cutoff)}), #{pct(now[:accuracy])} correct, " \
            "as good as any cutoff for this file."
        elsif best[:accuracy] == now[:accuracy]
          "Recommendation: set retrieval.max_distance to #{fmt_cutoff(best[:cutoff])}. Same share correct " \
            "(#{pct(now[:accuracy])}) as the current #{fmt_cutoff(@cutoff)}, but #{best[:false_answers]} wrong " \
            "answer(s) instead of #{now[:false_answers]}: it refuses where it would otherwise answer without support.#{margin}"
        else
          "Recommendation: set retrieval.max_distance to #{fmt_cutoff(best[:cutoff])} " \
            "(#{pct(best[:accuracy])} correct, vs #{pct(now[:accuracy])} at the current #{fmt_cutoff(@cutoff)}).#{margin}"
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

      def missing_titles(result)
        kept = Scorer.selected(result, @cutoff).map(&:document_id)
        (Array(result[:needs]) - kept).map { |key| title(key) }.join(" or ")
      end

      def closest_in(result, key)
        result[:candidates].select { |c| c[:document] == key }.map { |c| c[:distance] }.min
      end

      def title(key) = @documents&.dig(key, :title) || key

      def pct(x) = self.class.pct(x)
      def fmt_dist(d) = d.nil? ? "none" : format("%.3f", d)
      def fmt_cutoff(c) = self.class.fmt_cutoff(c)

      def self.pct(x) = "#{(x * 100).round}%"
      # 0.6 -> "0.60", 0.357 -> "0.357"; more digits only when the setting needs them.
      def self.fmt_cutoff(c)
        return "off" if c.nil?
        return format("%.4f", c) if ((c * 1000) - (c * 1000).round).abs > 1e-6

        text = format("%.3f", c)
        text.end_with?("0") ? text.chop : text
      end
    end
  end
end