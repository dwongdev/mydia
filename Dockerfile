# ============================================
# Flutter Build Stage
# ============================================
FROM ghcr.io/cirruslabs/flutter:stable AS flutter-builder

WORKDIR /app/player

# Copy player source
COPY player/pubspec.yaml player/pubspec.lock ./
COPY player/build.yaml ./
COPY player/lib ./lib
COPY player/web ./web
COPY player/rust_builder ./rust_builder

# Copy the GraphQL schema (resolves symlink from priv/graphql/)
COPY priv/graphql/schema.graphql ./lib/graphql/schema.graphql

# Install dependencies, generate code, and build
RUN flutter config --no-analytics && \
    flutter pub get && \
    dart run build_runner build --delete-conflicting-outputs && \
    flutter build web --release --base-href /player/

# ============================================
# Elixir Build Stage
# ============================================
FROM elixir:1.18-alpine AS builder

# Database type: sqlite (default) or postgres
# This is a BUILD-TIME argument that determines which database adapter is compiled into the release
# It CANNOT be changed at runtime - each Docker image is built for a specific database
ARG DATABASE_TYPE=sqlite

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    sqlite-dev \
    postgresql16-dev

# Set build environment
ENV MIX_ENV=prod
ENV DATABASE_TYPE=${DATABASE_TYPE}
# Increase hex timeout for slow networks/CI (5 minutes)
ENV HEX_HTTP_TIMEOUT=300000

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Create app directory
WORKDIR /app

# Copy dependency manifests
COPY mix.exs mix.lock ./

# Install dependencies
RUN mix deps.get --only prod

# Apply patches to dependencies
# Fix ueberauth_oidcc to respect user-provided response_mode option
# This prevents auto-selection of JARM modes (query.jwt) which some OIDC providers
# advertise but don't properly support
COPY patches/ueberauth_oidcc_request.ex ./deps/ueberauth_oidcc/lib/ueberauth_oidcc/request.ex

# Compile dependencies
RUN mix deps.compile

# Copy application source
COPY config ./config
COPY priv ./priv
COPY lib ./lib
COPY assets ./assets

# Copy Flutter build output from flutter-builder stage
COPY --from=flutter-builder /app/player/build/web ./priv/static/player

# Compile application
RUN mix compile

# Build Phoenix assets
RUN cd assets && \
    npm ci --prefix . --progress=false --no-audit --loglevel=error && \
    cd .. && \
    mix assets.deploy

# Build release
RUN mix release

# ============================================
# Runtime Stage
# ============================================
FROM erlang:27-alpine

# Database type: sqlite (default) or postgres
# This argument is only used for image labels - the actual adapter is already compiled
ARG DATABASE_TYPE=sqlite

# Add OCI labels following LinuxServer.io standards
LABEL org.opencontainers.image.title="Mydia" \
      org.opencontainers.image.description="Modern, self-hosted media management platform" \
      org.opencontainers.image.url="https://github.com/getmydia/mydia" \
      org.opencontainers.image.source="https://github.com/getmydia/mydia" \
      org.opencontainers.image.vendor="Mydia" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.database="${DATABASE_TYPE}" \
      maintainer="Mydia"

# Install runtime dependencies including LSIO-compatible tools
# libpq is needed for PostgreSQL connections at runtime
# sqlite provides the sqlite3 CLI for database inspection
# openssl is needed for self-signed certificate generation
RUN apk add --no-cache \
    sqlite \
    libpq \
    curl \
    ca-certificates \
    ffmpeg \
    fdk-aac \
    su-exec \
    tzdata \
    shadow \
    openssl

# Create app user with default UID/GID (will be updated by entrypoint if needed)
RUN addgroup -g 1000 mydia && \
    adduser -D -u 1000 -G mydia mydia

# Create necessary directories with proper permissions
RUN mkdir -p /app /config /data /media && \
    chown -R mydia:mydia /app /config /data /media

# Set working directory
WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=mydia:mydia /app/_build/prod/rel/mydia ./

# Copy entrypoint script
COPY docker-entrypoint-prod.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Copy CLI wrapper script
COPY scripts/mydia-cli.sh /usr/local/bin/mydia-cli
RUN chmod +x /usr/local/bin/mydia-cli

# Set environment variables
# Note: DATABASE_TYPE is NOT set here - it's a build-time argument only
# The database adapter is compiled into the release and cannot be changed at runtime
ENV HOME=/app \
    MIX_ENV=prod \
    PHX_SERVER=true \
    DATABASE_PATH=/config/mydia.db \
    PORT=4000 \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC

# Expose HTTP and HTTPS ports
EXPOSE 4000 4443

# Declare volumes following LSIO conventions
VOLUME ["/config", "/data", "/media"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

# Set entrypoint and default command
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/app/bin/mydia", "start"]
