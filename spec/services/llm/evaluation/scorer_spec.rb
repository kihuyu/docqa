# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Evaluation::Scorer do
  # Results without :candidates, as older runs recorded them.
  def result(expect, distance, top_hit = nil)
    { expect: expect, best_distance: distance, top_hit: top_hit }
  end

  def passage(document, distance, needed = false) = { document: document, distance: distance, needed: needed }

  def searched(expect, passages, needs: [], top_k: 6)
    passages = passages.sort_by { |p| p[:distance] }
    { expect: expect, needs: needs, top_k: top_k, candidates: passages, best_distance: passages.first&.fetch(:distance) }
  end

  let(:results) do
    [result("answer", 0.20, true), result("answer", 0.40, true), result("answer", 0.55, false),
     result("refuse", 0.62), result("refuse", 0.70), result("refuse", nil)]
  end
  subject(:scorer) { described_class.new(results) }

  it "measures how often the right passage ranks first" do
    expect(scorer.top1_accuracy).to eq(0.667)
  end

  it "scores a cutoff" do
    expect(scorer.at(0.6)).to include(accuracy: 1.0, false_answers: 0, false_refusals: 0)
    expect(scorer.at(0.5)).to include(false_refusals: 1)
    expect(scorer.at(0.65)).to include(false_answers: 1)
  end

  it "treats no cutoff as answering whenever anything was retrieved" do
    expect(scorer.at(nil)).to include(false_answers: 2)
  end

  it "recommends the middle of the gap, not the nearest grid value" do
    expect(scorer.recommended).to include(cutoff: 0.585, accuracy: 1.0, margin: 0.035)
  end

  it "finds a gap narrower than the grid step" do
    narrow = described_class.new([result("answer", 0.21), result("answer", 0.349), result("refuse", 0.366)])
    expect(narrow.recommended[:cutoff]).to be_between(0.349, 0.366).exclusive
    expect(narrow.recommended[:accuracy]).to eq(1.0)
  end

  it "prefers refusing to answering wrongly when accuracy ties" do
    tied = described_class.new([result("answer", 0.5, true), result("refuse", 0.45)])
    expect(tied.recommended[:false_answers]).to eq(0)
  end

  it "reports whether the two groups separate cleanly" do
    expect(scorer.separation).to include(clean: true, farthest_answerable: 0.55, closest_unanswerable: 0.62, midpoint: 0.585)
    expect(described_class.new([result("answer", 0.7), result("refuse", 0.5)]).separation[:clean]).to be(false)
  end

  describe "questions over several documents" do
    # Needs both documents; the shipping passage is farther than 0.357.
    let(:two_part) do
      searched("answer", [passage("returns", 0.30, true), passage("returns", 0.40), passage("shipping", 0.41, true)],
               needs: %w[returns shipping])
    end

    it "counts an answer missing a needed document as incomplete" do
      expect(described_class.outcome(two_part, 0.357)).to eq(:incomplete)
      expect(described_class.outcome(two_part, 0.45)).to eq(:correct)
      expect(described_class.outcome(two_part, 0.25)).to eq(:false_refusal)
    end

    it "counts an answer from the wrong document as incomplete" do
      wrong = searched("answer", [passage("returns", 0.30), passage("shipping", 0.38, true)], needs: %w[shipping])
      expect(described_class.outcome(wrong, 0.35)).to eq(:incomplete)
    end

    it "decides by the farthest needed document" do
      expect(described_class.required_distance(two_part)).to eq(0.41)

      scorer = described_class.new([two_part, searched("refuse", [passage("returns", 0.44)])])
      expect(scorer.separation).to include(clean: true, farthest_answerable: 0.41, closest_unanswerable: 0.44)
      expect(scorer.recommended).to include(cutoff: 0.425, accuracy: 1.0)
    end

    it "replays the app's selection, including top_k" do
      # With top_k 2, each document's best passage takes a slot, so the
      # needed shipping passage (shipping's second best) is left out.
      crowded = searched("answer", [passage("returns", 0.2, true), passage("shipping", 0.21), passage("shipping", 0.22, true)],
                         needs: %w[returns shipping], top_k: 2)
      coverage = described_class.new([crowded]).coverage(0.5)

      expect(coverage).to include(questions: 1, all_documents: 1, all_passages: 0)
      expect(coverage[:misses].first[:missing_passages]).to eq(["shipping"])
    end
  end
end