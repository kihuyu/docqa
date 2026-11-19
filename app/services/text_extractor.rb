# frozen_string_literal: true

require "pdf-reader"

# Turns an uploaded file into plain text for a Document.
#
# Supports PDF (text layer only, no OCR), plain text and Markdown. The file
# type is decided from the file's first bytes and its extension, never from
# the Content-Type the browser sends, which is easy to fake.
#
# Anything a visitor can fix raises TextExtractor::Unreadable with a message
# written for them; the controller shows it as-is.
class TextExtractor
  class Unreadable < StandardError; end

  MAX_BYTES = AppSetting.integer(:limits, :max_upload_bytes, default: 10 * 1024 * 1024)
  MAX_PDF_PAGES = AppSetting.integer(:limits, :max_pdf_pages, default: 300)
  TEXT_EXTENSIONS = %w[.txt .text .md .markdown].freeze
  PDF_SIGNATURE = "%PDF-"

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  # io: anything with read/rewind (an uploaded file's tempfile).
  # Returns { title:, content: }.
  def call(io:, filename:)
    filename = File.basename(filename.to_s)
    size = io.respond_to?(:size) ? io.size : nil
    if size && size > MAX_BYTES
      raise Unreadable, "This file is #{megabytes(size)}. The limit is #{megabytes(MAX_BYTES)}."
    end

    io.rewind
    head = io.read(PDF_SIGNATURE.bytesize).to_s.b
    io.rewind
    extension = File.extname(filename).downcase

    content = if head == PDF_SIGNATURE.b
                pdf_text(io)
              elsif extension == ".pdf"
                raise Unreadable, "This file is named .pdf but isn't a PDF."
              elsif TEXT_EXTENSIONS.include?(extension)
                plain_text(io)
              else
                raise Unreadable, "Only PDF, TXT and Markdown (.md) files can be added."
              end

    check_length!(content)
    { title: title_from(filename), content: content }
  end

  private

  def pdf_text(io)
    reader = PDF::Reader.new(io)
    if reader.page_count > MAX_PDF_PAGES
      raise Unreadable, "This PDF has #{reader.page_count} pages. The limit is #{MAX_PDF_PAGES}."
    end

    pages = reader.pages.map { |page| tidy(page.text) }.reject(&:empty?)
    if pages.empty?
      raise Unreadable, "This PDF has no text to read. It may be a scanned image; " \
        "this app can't read text from images."
    end

    pages.join("\n\n")
  rescue PDF::Reader::EncryptedPDFError
    raise Unreadable, "This PDF is password-protected. Remove the password and try again."
  rescue Unreadable
    raise
  rescue StandardError => e
    # pdf-reader raises a range of errors on damaged or unusual files.
    @logger.warn("[TextExtractor] PDF failed: #{e.class}: #{e.message}")
    raise Unreadable, "This PDF couldn't be read. It may be damaged or use features this app doesn't support."
  end

  def plain_text(io)
    bytes = io.read.to_s.b
    text = bytes.sub(/\A\xEF\xBB\xBF/n, "").force_encoding(Encoding::UTF_8)
    # Not valid UTF-8: most often a Windows "ANSI" file, so read it as that.
    text = bytes.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "") unless text.valid_encoding?
    raise Unreadable, "This file doesn't look like text." if text.include?("\u0000")

    text = text.gsub(/\r\n?/, "\n").strip
    raise Unreadable, "This file is empty." if text.empty?

    text
  end

  # pdf-reader lays text out with runs of spaces to keep columns aligned.
  # Collapse those, trim each line, and keep paragraph breaks.
  def tidy(text)
    text.to_s
        .gsub(/\r\n?/, "\n")
        .gsub(/[ \t ]+/, " ")
        .lines.map(&:strip).join("\n")
        .gsub(/\n{3,}/, "\n\n")
        .strip
  end

  def check_length!(content)
    limit = Document::MAX_CONTENT_CHARS
    return if content.length <= limit

    raise Unreadable, "This file contains #{content.length.to_fs(:delimited)} characters of text. " \
      "The limit is #{limit.to_fs(:delimited)}."
  end

  def title_from(filename)
    File.basename(filename, ".*").tr("_", " ").squeeze(" ").strip.presence&.truncate(300) || "Untitled"
  end

  def megabytes(bytes)
    "#{(bytes / 1024.0 / 1024.0).round(1)} MB"
  end
end
