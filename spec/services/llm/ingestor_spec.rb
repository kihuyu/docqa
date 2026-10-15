# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Ingestor do
  include ActiveJob::TestHelper

  def chunks_for(text)
    described_class.new.send(:chunks_for, text)
  end

  it "saves the document and its chunks, then enqueues embedding" do
    expect {
      described_class.new.call(title: "Policy", content: "Refunds take 5-7 days. " * 100)
    }.to have_enqueued_job(EmbedChunksJob)

    document = Document.last
    expect(document.status).to eq("processing")
    expect(document.chunks.count).to be > 1
  end

  it "never splits a word, and every chunk is an exact piece of the text" do
    words = %w[refunds processed within business days warehouse inspection shipping]
    text = Array.new(600) { |i| words[i % words.size] }.join(" ")

    chunks_for(text).each do |chunk|
      start = text.index(chunk)
      expect(start).not_to be_nil
      expect(chunk.length).to be <= described_class::CHUNK_SIZE
      expect(start.zero? || text[start - 1].match?(/\s/)).to be(true)
      finish = start + chunk.length
      expect(finish == text.length || text[finish].match?(/\s/)).to be(true)
    end
  end

  it "overlaps neighbouring chunks and covers the whole text" do
    text = (1..400).map { |i| "word#{i}" }.join(" ")
    chunks = chunks_for(text)

    chunks.each_cons(2) do |a, b|
      expect(text.index(b)).to be < text.index(a) + a.length # overlap
    end
    expect(text).to start_with(chunks.first)
    expect(text).to end_with(chunks.last)
  end

  it "cuts an unbroken run of characters at the chunk size" do
    expect(chunks_for("x" * 2000).map(&:length).max).to eq(described_class::CHUNK_SIZE)
  end

  it "rolls back the document if a chunk fails to save" do
    allow_any_instance_of(Chunk).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)

    expect {
      described_class.new.call(title: "Policy", content: "Some text")
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect(Document.count).to eq(0)
    expect(EmbedChunksJob).not_to have_been_enqueued
  end
end
