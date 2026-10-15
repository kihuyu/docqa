# frozen_string_literal: true

require "rails_helper"

RSpec.describe PurgeOldDocumentsJob do
  it "deletes documents older than the cutoff, with their passages, and keeps newer ones" do
    old = Document.create!(title: "Old", content: "x", status: "ready", created_at: 25.hours.ago)
    old.chunks.create!(content: "old passage")
    fresh = Document.create!(title: "Fresh", content: "y", status: "ready", created_at: 1.hour.ago)

    described_class.perform_now(24)

    expect(Document.exists?(old.id)).to be(false)
    expect(Chunk.where(document_id: old.id)).to be_empty
    expect(Document.exists?(fresh.id)).to be(true)
  end
end
