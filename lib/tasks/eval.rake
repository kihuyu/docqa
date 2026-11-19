# frozen_string_literal: true

namespace :eval do
  desc "Measure retrieval and refusals on eval/*.yml with real Gemini calls, and find the best cutoff. " \
         "Options: FILE=path (default: every eval/*.yml), ANSWERS=1 (also check the model's answers; slower), " \
         "PAUSE=seconds, MIN_ACCURACY=0.9"
  task run: :environment do
    paths = if ENV["FILE"].present?
              [ENV["FILE"]]
            else
              Dir[Rails.root.join("eval/*.yml")].sort
            end
    abort "No evaluation files found in eval/." if paths.empty?

    answers = ENV["ANSWERS"] == "1"
    cutoff = Llm::Retriever::MAX_DISTANCE
    reports = []
    saved = []

    paths.each do |path|
      name = File.basename(path, ".yml")
      puts "Evaluating #{path}#{' (with model answers, pausing between them for the rate limit)' if answers}..."
      runner = Llm::Evaluation::Runner.new(path: path, answers: answers, pause: Float(ENV.fetch("PAUSE", "6")))
      results = runner.run
      report = Llm::Evaluation::Report.new(results, current_cutoff: cutoff, documents: runner.documents, name: name)
      puts
      puts report
      puts
      reports << report
      saved << { file: path.to_s.delete_prefix("#{Rails.root}/"), summary: report.summary, results: results }
    end

    puts Llm::Evaluation::Report.overall(reports, current_cutoff: cutoff) if reports.size > 1

    # Keep a copy so runs can be compared after changing chunking, models or prompts.
    dir = Rails.root.join("tmp/eval")
    FileUtils.mkdir_p(dir)
    file = dir.join("#{Time.now.strftime('%Y%m%d-%H%M%S')}.json")
    File.write(file, JSON.pretty_generate(files: saved))
    puts "\nSaved to #{file.relative_path_from(Rails.root)}"

    if (min = ENV["MIN_ACCURACY"])
      low = reports.map(&:summary).select { |s| s[:accuracy] < Float(min) }
      abort low.map { |s| "#{s[:name]}: accuracy #{s[:accuracy]} is below MIN_ACCURACY=#{min}" }.join("\n") if low.any?
    end
  end
end