# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppSetting do
  # Stand-in for Rails.application.credentials backed by a plain hash.
  let(:creds) { {} }
  let(:fake_credentials) do
    hash = creds
    Object.new.tap do |o|
      o.define_singleton_method(:dig) { |*path| hash.dig(*path) }
    end
  end

  before { allow(Rails.application).to receive(:credentials).and_return(fake_credentials) }

  around do |example|
    example.run
  ensure
    ENV.delete("APP_SETTING_TEST")
  end

  describe ".fetch" do
    context "with a value in credentials" do
      let(:creds) { { gemini: { chat_model: "from-credentials" } } }

      it "prefers credentials over the env var and default" do
        ENV["APP_SETTING_TEST"] = "from-env"
        expect(described_class.fetch(:gemini, :chat_model, env: "APP_SETTING_TEST", default: "d"))
          .to eq("from-credentials")
      end
    end

    it "falls back to the env var, then the default" do
      expect(described_class.fetch(:gemini, :chat_model, env: "APP_SETTING_TEST", default: "d")).to eq("d")
      ENV["APP_SETTING_TEST"] = "from-env"
      expect(described_class.fetch(:gemini, :chat_model, env: "APP_SETTING_TEST", default: "d")).to eq("from-env")
    end

    context "with false in credentials" do
      let(:creds) { { retrieval: { max_distance: false } } }

      it "keeps false instead of falling through to the default" do
        expect(described_class.fetch(:retrieval, :max_distance, default: 0.6)).to be(false)
      end
    end
  end

  describe ".integer" do
    let(:creds) { { limits: { max_question_chars: "500", bad: "abc" } } }

    it "converts strings and rejects junk" do
      expect(described_class.integer(:limits, :max_question_chars, default: 1)).to eq(500)
      expect { described_class.integer(:limits, :bad, default: 1) }.to raise_error(ArgumentError)
    end
  end

  describe ".optional" do
    it "returns nil when switched off, and the converted value otherwise" do
      expect(described_class.optional(:x, default: false)).to be_nil
      expect(described_class.optional(:x, default: "")).to be_nil
      expect(described_class.optional(:x, default: "0.4") { |v| Float(v) }).to eq(0.4)
    end
  end
end
