# frozen_string_literal: true

# One place to read app settings.
#
# Lookup order:
#   1. Rails credentials (bin/rails credentials:edit), e.g. gemini.chat_model
#   2. An environment variable, e.g. LLM_CHAT_MODEL — used by CI and tests,
#      which have no master key
#   3. The default given here
#
# A credentials value of `false` is kept (not skipped), so settings that can be
# switched off — like the retrieval cutoff — can be turned off from credentials.
module AppSetting
  module_function

  def fetch(*path, env: nil, default: nil)
    value = Rails.application.credentials.dig(*path)
    return value unless value.nil?

    env_value = env && ENV[env]
    return env_value unless env_value.nil?

    default
  end

  # Integer setting; raises on junk like "abc" rather than silently using 0.
  def integer(*path, env: nil, default:)
    Integer(fetch(*path, env: env, default: default))
  end

  # A setting that may be switched off with `false` or an empty value.
  # Returns nil when off, otherwise the value converted with the block.
  def optional(*path, env: nil, default:)
    value = fetch(*path, env: env, default: default)
    return nil if value == false || value.to_s.strip.empty?

    block_given? ? yield(value) : value
  end
end