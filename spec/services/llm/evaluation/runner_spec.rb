# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Evaluation::Runner do
  EvalPassage = Struct.new(:content, :document_id, :neighbor_distance)
  EvalReply = Struct.new(:answer, :sources) { def to_h = { answer: answer, sources: sources } }

  def write_file(data)
    Rails.root.join("tmp/eval_runner_spec.yml").tap { |file| File.write(file, data.to_yaml) }
  end

  # Returns the passages listed for each question as [document title, text,
  # distance], so the spec controls ranking without real embeddings.
  def fake_retriever(ranked)
    Object.new.tap do |r|
      r.define_singleton_method(:candidates) do |question:, document_ids:, top_k: nil|
        by_title = Document.where(id: document_ids).index_by { |d| d.title.delete_prefix("[eval] ") }
        ranked.fetch(question).filter_map do |title, text, distance|
          (doc = by_title[title]) && EvalPassage.new(text, doc.id, distance)
        end
      end
    end
  end

  before do
    vector = Array.new(Llm::Client::EMBED_DIMS, 0.0).tap { |v| v[0] = 1.0 }
    allow_any_instance_of(Llm::Client).to receive(:embed).and_return(vector)
  end

  describe "with one document" do
    let(:path) do
      write_file(
        "document" => { "title" => "Policy", "content" => "Returns within 30 days. Footwear in its original box." },
        "cases" => [
          { "question" => "Q1", "expect" => "answer", "passage" => "30 days", "answer_includes_any" => ["30 days"] },
          { "question" => "Q2", "expect" => "answer", "passage" => "box", "answer_includes_any" => ["box"] },
          { "question" => "Q3", "expect" => "refuse", "kind" => "in_domain" }
        ]
      )
    end

    let(:retriever) do
      fake_retriever(
        "Q1" => [["Policy", "Returns within 30 days.", 0.21], ["Policy", "other", 0.5]],
        "Q2" => [["Policy", "other", 0.3], ["Policy", "original box", 0.35]],
        "Q3" => [["Policy", "other", 0.71]]
      )
    end

    it "records ranks and distances, then deletes its document" do
      results = described_class.new(path: path, retriever: retriever).run

      expect(results.map { |r| r[:top_hit] }).to eq([true, false, nil])
      expect(results.map { |r| r[:hit_rank] }).to eq([1, 2, nil])
      expect(results.map { |r| r[:best_distance] }).to eq([0.21, 0.3, 0.71])
      expect(results.first).to include(needs: ["document"], top_k: Llm::Retriever::DEFAULT_TOP_K)
      expect(Document.where("title LIKE ?", "[eval]%")).to be_empty
    end

    it "checks the model's answers when asked to" do
      answerer = double(call: nil)
      allow(answerer).to receive(:call) do |document_ids:, question:|
        {
          "Q1" => EvalReply.new("You have 30 days.", [1]),
          "Q2" => EvalReply.new("The document doesn't say anything about boxes.", [1]),
          "Q3" => EvalReply.new("I don't have enough information to answer that from the provided documents.", [])
        }.fetch(question)
      end

      results = described_class.new(path: path, retriever: retriever, answerer: answerer,
                                    answers: true, pause: 0).run

      expect(results.map { |r| r[:answer_ok] }).to eq([true, false, true])
    end
  end

  describe "with several documents" do
    let(:documents) do
      {
        "returns" => { "title" => "Returns", "content" => "Returns within 30 days." },
        "shipping" => { "title" => "Shipping", "content" => "Delivery takes 3-5 days." }
      }
    end

    let(:path) do
      write_file(
        "documents" => documents,
        "cases" => [
          { "question" => "Both?", "expect" => "answer",
            "passages" => { "returns" => "30 days", "shipping" => "3-5 days" },
            "answer_includes_each" => [["30"], ["3-5", "three to five"]] },
          { "question" => "Delivery?", "expect" => "answer", "passages" => { "shipping" => "3-5 days" } },
          { "question" => "PayPal?", "expect" => "refuse", "search" => ["returns"] }
        ]
      )
    end

    let(:retriever) do
      fake_retriever(
        "Both?" => [["Returns", "Returns within 30 days.", 0.3], ["Shipping", "Delivery takes 3-5 days.", 0.41]],
        "Delivery?" => [["Shipping", "Delivery takes 3-5 days.", 0.2], ["Returns", "Returns within 30 days.", 0.5]],
        "PayPal?" => [["Returns", "Returns within 30 days.", 0.6]]
      )
    end

    it "records each passage's document so the scorer can replay the selection" do
      runner = described_class.new(path: path, retriever: retriever)
      both, delivery, paypal = runner.run

      expect(runner.documents).to eq("returns" => { title: "Returns", passages: 1 },
                                     "shipping" => { title: "Shipping", passages: 1 })
      expect(both).to include(needs: %w[returns shipping], top_k: Llm::Retriever::MULTI_DOCUMENT_TOP_K)
      expect(both).not_to have_key(:top_hit) # ranking is only measured for one-passage questions
      expect(both[:candidates]).to eq([{ document: "returns", distance: 0.3, needed: true },
                                       { document: "shipping", distance: 0.41, needed: true }])
      expect(delivery).to include(top_hit: true, top_document_hit: true)
      expect(paypal).to include(search: ["returns"], needs: [])
      expect(Llm::Evaluation::Scorer.outcome(both, 0.357)).to eq(:incomplete)
      expect(Document.where("title LIKE ?", "[eval]%")).to be_empty
    end

    it "needs every group of words in the answer, and counts a half-refusal as a miss" do
      searched = {}
      answerer = double(call: nil)
      allow(answerer).to receive(:call) do |document_ids:, question:|
        searched[question] = document_ids
        {
          "Both?" => EvalReply.new("30 days (Returns). The passages don't say how long delivery takes.", [1]),
          "Delivery?" => EvalReply.new("3-5 days, according to Shipping.", [1]),
          "PayPal?" => EvalReply.new("I don't have enough information to answer that from the provided documents.", [])
        }.fetch(question)
      end

      results = described_class.new(path: path, retriever: retriever, answerer: answerer, answers: true, pause: 0).run

      expect(results.map { |r| r[:answer_ok] }).to eq([false, true, true])
      expect(searched.transform_values(&:size)).to eq("Both?" => 2, "Delivery?" => 2, "PayPal?" => 1)
    end
  end

  describe "checking the file" do
    let(:two) do
      { "returns" => { "title" => "Returns", "content" => "Returns within 30 days." },
        "shipping" => { "title" => "Shipping", "content" => "Delivery takes 3-5 days." } }
    end

    it "rejects an unknown document or an ambiguous `passage:` before creating anything" do
      [{ "question" => "Q", "expect" => "answer", "passages" => { "billing" => "x" } },
       { "question" => "Q", "expect" => "answer", "passage" => "30 days" }].each do |bad|
        path = write_file("documents" => two, "cases" => [bad])

        expect { described_class.new(path: path, retriever: fake_retriever({})).run }
          .to raise_error(described_class::InvalidFile, /"Q"/)
      end
      expect(Document.count).to eq(0)
    end

    it "stops before embedding when no passage contains a phrase" do
      path = write_file("documents" => two,
                        "cases" => [{ "question" => "Q", "expect" => "answer", "passages" => { "returns" => "60 days" } }])
      expect_any_instance_of(EmbedChunksJob).not_to receive(:perform)

      expect { described_class.new(path: path, retriever: fake_retriever({})).run }
        .to raise_error(described_class::InvalidFile, /no passage of returns contains "60 days"/)
      expect(Document.count).to eq(0)
    end
  end

  it "doesn't count a real answer as a refusal" do
    pattern = described_class::MODEL_REFUSAL
    expect("You don't have to pay return shipping on orders over $75.").not_to match(pattern)
    expect("No, the warranty doesn't cover accidents.").not_to match(pattern)
    expect("The document doesn't mention PayPal.").to match(pattern)
  end

  it "finds every phrase in the bundled evaluation files" do
    Dir[Rails.root.join("eval/*.yml")].each do |file|
      data = YAML.safe_load_file(file)
      docs = data["documents"] || { "document" => data["document"] }
      chunks = docs.transform_values { |d| Llm::Ingestor.new.send(:chunks_for, d["content"]) }

      data["cases"].each do |c|
        needs = c["passages"] || (c["passage"] ? { docs.keys.first => c["passage"] } : {})
        needs.each do |key, phrase|
          expect(chunks.fetch(key).any? { |chunk| chunk.include?(phrase) })
            .to be(true), "#{File.basename(file)}: #{c['question']}: no #{key} passage contains #{phrase.inspect}"
        end
      end
    end
  end
end