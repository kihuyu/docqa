# frozen_string_literal: true

# Deletes documents (and their passages) older than a set age, so a public demo
# doesn't keep what visitors paste and the free database stays small.
# Scheduled hourly in config/recurring.yml.
class PurgeOldDocumentsJob < ApplicationJob
  queue_as :default

  def perform(hours = AppSetting.integer(:limits, :document_ttl_hours, default: 24))
    cutoff = hours.hours.ago
    count = 0
    Document.where(created_at: ...cutoff).find_each do |document|
      document.destroy
      count += 1
    end
    Rails.logger.info("[PurgeOldDocumentsJob] deleted #{count} document(s) older than #{hours}h")
  end
end