# frozen_string_literal: true

require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
# Specs never call the real API (the client is stubbed), but Llm::Client.new
# still reads the key at construction, so provide a dummy one.
ENV["LLM_API_KEY"] ||= "test-key"
require_relative "../config/environment"

abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

# Load support files (shared examples, helpers).
Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }

# No committed schema.rb — the test database is built from migrations, keeping
# the app and Solid Queue tables in one source of truth. `RAILS_ENV=test bin/rails
# db:create db:migrate` builds it; this just verifies nothing is pending.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort "#{e}\nRun: RAILS_ENV=test bin/rails db:create db:migrate"
rescue ActiveRecord::NoDatabaseError
  abort "Test database does not exist. Run: RAILS_ENV=test bin/rails db:create db:migrate"
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Rate-limit counts persist in memory across examples; start each test fresh.
  config.before { ApplicationController::RATE_LIMIT_STORE.clear }
end
