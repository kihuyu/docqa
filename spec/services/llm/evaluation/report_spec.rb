# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Evaluation::Report do
  let(:documents) { { "returns" => { title: "Returns", passages: 3 }, "shipping" => { title: "Shipping", passages: 4 } } }
  let(:results) do
    [
      { question: "Both?", expect: "answer", needs: %w[returns shipping], top_k: 6, best_distance: 0.30,
        candidates: [{ document: "returns", distance: 0.30, needed: true }, { document: "shipping", distance: 0.41, needed: true }] },
      { question: "PayPal?", expect: "refuse", kind: "in_domain", needs: [], top_k: 6, best_distance: 0.5,
        candidates: [{ document: "returns", distance: 0.5, needed: false }] }
    ]
  end
  subject(:report) { described_class.new(results, current_cutoff: 0.357, documents: documents, name: "policies") }

  it "explains which document a cross-document answer would miss" do
    text = report.to_s

    expect(text).to include("policies: 2 questions over Returns (3 passages), Shipping (4 passages)")
    expect(text).to include("every needed document contributed a passage: 0 of 1")
    expect(text).to include("nothing from Shipping (closest 0.410)")
    expect(text).to include("<- answered without Shipping")
    expect(text).to match(/0\.455 .*<- recommended/)
  end

  it "summarises the headline numbers" do
    expect(report.summary).not_to have_key(:top1_accuracy) # no question here is answered by one passage
    expect(report.summary).to include(documents: 2, passages: 7, questions: 2, incomplete: 1,
                                      cross_document_questions: 1, cross_document_all_documents: 0,
                                      recommended_cutoff: 0.455, recommended_accuracy: 1.0)
  end

  it "gives one recommendation across several files" do
    other = described_class.new([{ question: "Q", expect: "answer", best_distance: 0.2, top_hit: true }],
                                current_cutoff: 0.357, name: "returns")
    text = described_class.overall([report, other], current_cutoff: 0.357)

    expect(text).to include("All files together (3 questions)")
    expect(text).to include("Best single cutoff: 0.455")
  end

  it "prints cutoffs the way you'd type them into credentials" do
    expect([0.6, 0.357, 0.35, 0.3575, nil].map { |c| described_class.fmt_cutoff(c) })
      .to eq(["0.60", "0.357", "0.35", "0.3575", "off"])
  end
end
