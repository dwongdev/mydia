# ============================================
# Build Stage
# ============================================
FROM elixir:1.18-alpine AS builder

# Database type: sqlite (default) or postgres
# This is a BUILD-TIME argument that determines which database adapter is compiled into the release
# It CANNOT be changed at runtime - each Docker image is built for a specific database
ARG DATABASE_TYPE=sqlite

# Install build dependencies
# postgresql16-dev is needed for postgrex compilation
# Flutter build dependencies: bash, git, curl, unzip, xz
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    sqlite-dev \
    postgresql16-dev \
    curl \
    bash \
    unzip \
    xz

# Set build environment
ENV MIX_ENV=prod
ENV DATABASE_TYPE=${DATABASE_TYPE}

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install Flutter SDK
ARG FLUTTER_VERSION=3.24.0
ENV FLUTTER_HOME=/usr/local/flutter
ENV PATH="${FLUTTER_HOME}/bin:${PATH}"

RUN curl -fsSL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz -o flutter.tar.xz && \
    tar xf flutter.tar.xz -C /usr/local && \
    rm flutter.tar.xz && \
    flutter config --no-analytics && \
    flutter --version

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
COPY player ./player

# Compile application
RUN mix compile

# Build Flutter web player
RUN if [ -d "player" ]; then \
      cd player && \
      flutter pub get && \
      flutter pub run build_runner build --delete-conflicting-outputs && \
      flutter build web --release --base-href /player/ && \
      mkdir -p ../priv/static/player && \
      cp -r build/web/* ../priv/static/player/ && \
      cd ..; \
    fi

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
