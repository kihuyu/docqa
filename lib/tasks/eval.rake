# frozen_string_literal: true

namespace :eval do
  desc "Measure retrieval and refusals on eval/*.yml with real Gemini calls, and find the best cutoff. " \
       "Options: FILE=path, ANSWERS=1 (also check the model's answers; slower), PAUSE=seconds, MIN_ACCURACY=0.9"
  task run: :environment do
    path = ENV.fetch("FILE") { Rails.root.join("eval/returns_policy.yml").to_s }
    answers = ENV["ANSWERS"] == "1"
    puts "Evaluating #{path}#{' (with model answers, pausing between them for the rate limit)' if answers}..."

    runner = Llm::Evaluation::Runner.new(path: path, answers: answers,
                                         pause: Float(ENV.fetch("PAUSE", "6")))
    results = runner.run
    report = Llm::Evaluation::Report.new(results, current_cutoff: Llm::Retriever::MAX_DISTANCE)
    puts
    puts report

    # Keep a copy so runs can be compared after changing chunking, models or prompts.
    dir = Rails.root.join("tmp/eval")
    FileUtils.mkdir_p(dir)
    file = dir.join("#{Time.now.strftime('%Y%m%d-%H%M%S')}.json")
    File.write(file, JSON.pretty_generate(summary: report.summary, results: results))
    puts "\nSaved to #{file.relative_path_from(Rails.root)}"

    if (min = ENV["MIN_ACCURACY"]) && report.summary[:accuracy] < Float(min)
      abort "Accuracy #{report.summary[:accuracy]} is below MIN_ACCURACY=#{min}"
    end
  end
end
