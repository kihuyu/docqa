# frozen_string_literal: true

require "rails_helper"

RSpec.describe TextExtractor do
  subject(:extractor) { described_class.new(logger: Logger.new(IO::NULL)) }

  def extract(bytes, filename)
    extractor.call(io: StringIO.new(bytes.b), filename: filename)
  end

  def message_for(bytes, filename)
    extract(bytes, filename)
    raise "expected TextExtractor::Unreadable"
  rescue TextExtractor::Unreadable => e
    e.message
  end

  describe "PDF" do
    it "extracts text from every page and titles it after the file" do
      pdf = PdfBuilder.build("Refunds take 5-7 business days.", "Warranty (2 years) covers tents.")

      result = extract(pdf, "returns_policy.pdf")

      expect(result[:title]).to eq("returns policy")
      expect(result[:content]).to include("Refunds take 5-7 business days.")
      expect(result[:content]).to include("Warranty (2 years) covers tents.")
    end

    it "decides the type from the file's contents, not its name" do
      expect(extract(PdfBuilder.build("Real PDF text"), "renamed.txt")[:content]).to include("Real PDF text")
      expect(message_for("plain text", "fake.pdf")).to match(/isn't a PDF/)
    end

    it "explains when a PDF has no text layer" do
      expect(message_for(PdfBuilder.build("", ""), "scan.pdf")).to match(/no text to read.*scanned/)
    end

    it "explains when a PDF is damaged" do
      expect(message_for(PdfBuilder.build("Some text")[0, 120], "broken.pdf")).to match(/couldn't be read/)
    end

    it "refuses PDFs over the page limit" do
      stub_const("TextExtractor::MAX_PDF_PAGES", 2)
      expect(message_for(PdfBuilder.build("a", "b", "c"), "long.pdf")).to match(/3 pages\. The limit is 2/)
    end
  end

  describe "text files" do
    it "reads UTF-8, dropping a byte-order mark and Windows line endings" do
      result = extract("\xEF\xBB\xBFCafé menu\r\nCoffee costs 200 shillings.", "menu.txt")
      expect(result[:content]).to eq("Café menu\nCoffee costs 200 shillings.")
    end

    it "reads Windows-1252 files" do
      expect(extract("Caf\xE9 hours: 7am \x96 9pm", "hours.txt")[:content]).to eq("Café hours: 7am – 9pm")
    end

    it "keeps Markdown as written" do
      expect(extract("# Notes\n\nThe **launch** is Friday.", "notes.md")[:content]).to eq("# Notes\n\nThe **launch** is Friday.")
    end

    it "rejects binary, empty and unsupported files" do
      expect(message_for("abc\x00def", "data.txt")).to match(/doesn't look like text/)
      expect(message_for("  \n", "empty.txt")).to match(/empty/)
      expect(message_for("\xFF\xD8\xFF", "photo.jpg")).to match(/Only PDF, TXT and Markdown/)
    end
  end

  it "refuses files over the size limit" do
    io = StringIO.new("small")
    allow(io).to receive(:size).and_return(described_class::MAX_BYTES + 1)
    expect { extractor.call(io: io, filename: "big.txt") }
      .to raise_error(TextExtractor::Unreadable, /The limit is/)
  end

  it "refuses text longer than a document may be" do
    expect(message_for("a" * (Document::MAX_CONTENT_CHARS + 1), "long.txt")).to match(/characters of text\. The limit is/)
  end
end
