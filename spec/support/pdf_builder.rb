# frozen_string_literal: true

# Builds small, valid PDFs for tests, one page per string, so specs don't need
# binary fixture files. Pass an empty string for a page with no text (like a
# scanned page).
module PdfBuilder
  module_function

  def build(*pages)
    objects = []
    page_ids = []
    font_id = 3

    pages.each_with_index do |text, i|
      content_id = 4 + (i * 2)
      page_id = content_id + 1
      page_ids << page_id

      stream = text.to_s.lines.map(&:chomp).each_with_index.map do |line, n|
        escaped = line.gsub(/[\\()]/) { |c| "\\#{c}" }
        "BT /F1 12 Tf 72 #{720 - (n * 16)} Td (#{escaped}) Tj ET"
      end.join("\n")

      objects[content_id] = "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
      objects[page_id] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
        "/Contents #{content_id} 0 R /Resources << /Font << /F1 #{font_id} 0 R >> >> >>"
    end

    objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
    objects[2] = "<< /Type /Pages /Kids [#{page_ids.map { |id| "#{id} 0 R" }.join(' ')}] /Count #{page_ids.size} >>"
    objects[font_id] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

    pdf = +"%PDF-1.4\n"
    offsets = []
    (1...objects.size).each do |id|
      offsets[id] = pdf.bytesize
      pdf << "#{id} 0 obj\n#{objects[id]}\nendobj\n"
    end

    xref_at = pdf.bytesize
    pdf << "xref\n0 #{objects.size}\n0000000000 65535 f \n"
    (1...objects.size).each { |id| pdf << format("%010d 00000 n \n", offsets[id]) }
    pdf << "trailer\n<< /Size #{objects.size} /Root 1 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
    pdf
  end
end