# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Evaluation::Runner do
  Passage = Struct.new(:content, :neighbor_distance)
  Reply = Struct.new(:answer, :sources) { def to_h = { answer: answer, sources: sources } }

  let(:path) do
    file = Rails.root.join("tmp/eval_runner_spec.yml")
    File.write(file, {
      "document" => { "title" => "Policy", "content" => "Returns within 30 days. Footwear in its original box." },
      "cases" => [
        { "question" => "Q1", "expect" => "answer", "passage" => "30 days", "answer_includes_any" => ["30 days"] },
        { "question" => "Q2", "expect" => "answer", "passage" => "box", "answer_includes_any" => ["box"] },
        { "question" => "Q3", "expect" => "refuse", "kind" => "in_domain" }
      ]
    }.to_yaml)
    file
  end

  let(:ranked) do
    {
      "Q1" => [Passage.new("Returns within 30 days.", 0.21), Passage.new("other", 0.5)],
      "Q2" => [Passage.new("other", 0.3), Passage.new("original box", 0.35)],
      "Q3" => [Passage.new("other", 0.71)]
    }
  end

  let(:retriever) do
    map = ranked
    Object.new.tap do |r|
      r.define_singleton_method(:relevant_chunks) do |document_id:, question:, max_distance:|
        raise "the runner must retrieve without a cutoff" unless max_distance.nil?

        map.fetch(question)
      end
    end
  end

  before do
    vector = Array.new(Llm::Client::EMBED_DIMS, 0.0).tap { |v| v[0] = 1.0 }
    allow_any_instance_of(Llm::Client).to receive(:embed).and_return(vector)
  end

  it "records ranks and distances, then deletes its document" do
    results = described_class.new(path: path, retriever: retriever).run

    expect(results.map { |r| r[:top_hit] }).to eq([true, false, nil])
    expect(results.map { |r| r[:hit_rank] }).to eq([1, 2, nil])
    expect(results.map { |r| r[:best_distance] }).to eq([0.21, 0.3, 0.71])
    expect(Document.where("title LIKE ?", "[eval]%")).to be_empty
  end

  it "checks the model's answers when asked to" do
    answerer = double(call: nil)
    allow(answerer).to receive(:call) do |document_id:, question:|
      {
        "Q1" => Reply.new("You have 30 days.", [1]),
        "Q2" => Reply.new("The document doesn't say anything about boxes.", [1]),
        "Q3" => Reply.new("I don't have enough information to answer that from the provided documents.", [])
      }.fetch(question)
    end

    results = described_class.new(path: path, retriever: retriever, answerer: answerer,
                                  answers: true, pause: 0).run

    expect(results.map { |r| r[:answer_ok] }).to eq([true, false, true])
  end

  it "doesn't count a real answer as a refusal" do
    pattern = described_class::MODEL_REFUSAL
    expect("You don't have to pay return shipping on orders over $75.").not_to match(pattern)
    expect("No, the warranty doesn't cover accidents.").not_to match(pattern)
    expect("The document doesn't mention PayPal.").to match(pattern)
  end
end
