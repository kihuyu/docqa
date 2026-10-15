# syntax=docker/dockerfile:1
FROM ruby:3.2-slim

ENV RAILS_ENV=production \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=1 \
    RAILS_LOG_TO_STDOUT=1

WORKDIR /app

# libpq-dev: the pg gem. libyaml-dev + pkg-config: the psych gem, which
# recent Rails versions pull in and which fails to compile without them.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Install gems from the committed Gemfile.lock (BUNDLE_DEPLOYMENT refuses to
# build without one, so versions match what you tested locally).
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf ~/.bundle/ /usr/local/bundle/cache

COPY . .
RUN bundle exec bootsnap precompile app/ lib/ 2>/dev/null || true

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
