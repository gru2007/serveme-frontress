# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t frontend .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name frontend frontend

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .tool-versions
ARG RUBY_VERSION=4.0.5
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages used by both build and runtime stages.
# Pre-create dirs that the final-stage COPYs would otherwise materialize with
# build-time mtimes (BuildKit --link parent-dir reproducibility quirk).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl \
      libjemalloc2 \
      libvips && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* && \
    mkdir -p /var/cache/bootsnap /rails/public/assets

# Set production environment. LD_PRELOAD activates jemalloc for Ruby processes.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="libjemalloc.so.2" \
    MALLOC_CONF="dirty_decay_ms:1000,narenas:2,background_thread:true" \
    BOOTSNAP_CACHE_DIR="/var/cache/bootsnap"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems and compile Tailwind assets.
# Node/npm are intentionally build-only: the final Rails image does not need them.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      pkg-config \
      libmaxminddb0 \
      libmaxminddb-dev \
      libpq-dev \
      libyaml-dev \
      nodejs \
      npm && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Install application gems. Cache mount on the gem download cache preserves
# *.gem archives across layer invalidations, so a Gemfile bump only re-downloads
# gems whose versions actually changed.
#
# NB: target uses Ruby's API version (4.0.x -> 4.0.0). A future bump to Ruby 4.1
# should update this cache path too.
COPY Gemfile Gemfile.lock ./
RUN --mount=type=cache,target=/usr/local/bundle/ruby/4.0.0/cache,sharing=locked \
    bundle config set bin 'bin' && \
    bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile && \
    mkdir -p bin && \
    bundle binstubs thruster --force

# Copy application code
COPY . .

# tailwindcss-ruby 4.3.3 ships a standalone Tailwind binary that embeds Bun.
# Bun 1.3.14 crashes with SIGILL/segfault on CPUs/VMs where AVX is unavailable.
# Use the Node.js Tailwind CLI instead.
#
# Install it under /rails/node_modules (rather than /opt) because
# config/tailwind/v2.tailwind.css contains `@import "tailwindcss"`; Tailwind's
# resolver must be able to find the package through the project's node_modules.
RUN npm install \
      --prefix /rails \
      --no-save \
      --package-lock=false \
      tailwindcss@4.3.3 \
      @tailwindcss/cli@4.3.3

# tailwindcss-ruby honors this variable and calls our Node-backed CLI instead of
# its vendored Bun executable.
ENV TAILWINDCSS_INSTALL_DIR="/rails/node_modules/.bin"

# Skip `bootsnap precompile app/ lib/` — churns the code layer for ~200ms boot.

# Precompile assets for production without requiring a secret RAILS_MASTER_KEY.
# Cache mount on tmp/cache covers sprockets manifests + bootsnap caches so an
# app-only edit doesn't redo the full asset pipeline.
#
# Kamal's asset_path: /rails/public/assets in config/deploy.yml owns retention
# across deploys — on the host it extracts public/assets from this image,
# cross-syncs with the previous release, and mounts the per-version volume back
# over public/assets at run time.
RUN --mount=type=cache,target=/rails/tmp/cache,sharing=locked \
    --mount=type=cache,target=/var/cache/bootsnap,sharing=locked \
    SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    sed -i 's/"mtime":"[^"]*"/"mtime":"1970-01-01T00:00:00+00:00"/g' public/assets/.sprockets-manifest-*.json && \
    cd public/assets && \
    OLD=$(ls .sprockets-manifest-*.json) && \
    NEW=".sprockets-manifest-$(sha256sum "$OLD" | cut -c1-32).json" && \
    if [ "$OLD" != "$NEW" ]; then mv "$OLD" "$NEW"; fi && \
    cd /rails && \
    find public/assets -name '*.gz' | while read gz; do \
      src="${gz%.gz}"; \
      [ -f "$src" ] && gzip -9 -n < "$src" > "$gz"; \
    done && \
    find public/assets -exec touch -d '@0' {} + && \
    rm -rf /rails/node_modules

# Final stage for app image
FROM base

LABEL service=serveme

# Runtime libraries + tools the app shells out to:
#   libpq5, libmaxminddb0 — Rails DB / GeoIP
#   openssh-client        — scp/ssh/sftp
#   zip                   — local_zip_file_creator
#   ripgrep               — log_streaming_service.rb shells out to `rg`
# curl/libjemalloc2/libvips already come from the base stage.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libpq5 \
      libmaxminddb0 \
      libyaml-0-2 \
      openssh-client \
      zip \
      ripgrep && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Docker CLI — the app starts game server containers on the host's daemon over
# a bind-mounted /var/run/docker.sock (CloudProvider::Docker), and can rebuild
# the game server image with it (CloudImageBuildWorker). CLI binary only, no
# daemon.
ARG DOCKER_CLI_VERSION=29.4.2
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
    | tar -xzC /usr/local/bin --strip-components=1 docker/docker

# Final-stage COPYs ordered by churn frequency. --link makes each layer's digest
# content-addressable so identical sources cache-hit on the registry.
COPY --from=build --link /rails/public/assets /rails/public/assets
COPY --from=build --link "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build --link /var/cache/bootsnap /var/cache/bootsnap
COPY --from=build --link --exclude=public/assets /rails /rails

# Run and own only the runtime files as a non-root user for security.
#
# Every path compose mounts a named volume on is created here as well. Docker
# initialises an empty named volume from whatever is at that path in the image,
# ownership included -- but when the path does not exist in the image it makes
# the mountpoint root-owned, and this container runs as uid 1000. That is what
# made ReservationCleanupWorker die with EACCES writing the reservation zip
# into public/uploads. Creating them here keeps the volumes writable.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p db log storage tmp tmp/pids tmp/maps \
             public/uploads public/system server_logs && \
    chown -R rails:rails db log storage tmp public/uploads public/system server_logs

USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
