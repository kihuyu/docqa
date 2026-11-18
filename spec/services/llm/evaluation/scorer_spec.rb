# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Evaluation::Scorer do
  def result(expect, distance, top_hit = nil)
    { expect: expect, best_distance: distance, top_hit: top_hit }
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

  it "recommends a cutoff that gets everything right when one exists" do
    expect(scorer.recommended[:cutoff]).to eq(0.6)
  end

  it "prefers refusing to answering wrongly when accuracy ties" do
    tied = described_class.new([result("answer", 0.5, true), result("refuse", 0.45)])
    expect(tied.recommended[:false_answers]).to eq(0)
  end

  it "reports whether the two groups separate cleanly" do
    expect(scorer.separation).to include(clean: true, farthest_answerable: 0.55, closest_unanswerable: 0.62)
    expect(described_class.new([result("answer", 0.7), result("refuse", 0.5)]).separation[:clean]).to be(false)
  end
end
