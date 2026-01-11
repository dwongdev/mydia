# syntax=docker/dockerfile:1.4
FROM elixir:1.18-alpine AS builder

# Install build dependencies
RUN apk add --no-cache build-base git openssl-dev

# Set build environment
ENV MIX_ENV=prod
ENV HEX_HOME=/root/.hex
ENV MIX_HOME=/root/.mix

WORKDIR /app

# Install hex and rebar with cache
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./

# Install dependencies with cache
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    --mount=type=cache,target=/app/deps \
    mix deps.get --only prod && \
    cp -r deps deps_copy

# Restore deps from cache copy
RUN rm -rf deps && mv deps_copy deps

# Compile dependencies with cache
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    --mount=type=cache,target=/app/_build,sharing=locked \
    mix deps.compile && \
    cp -r _build _build_copy

# Restore _build from cache copy
RUN rm -rf _build && mv _build_copy _build

# Copy application files
COPY config ./config
COPY lib ./lib
COPY priv ./priv

# Compile the application
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix compile

# Build release
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix release

# Start a new stage for the final image
FROM alpine:3.22

# Install runtime dependencies
RUN apk add --no-cache libstdc++ openssl ncurses-libs curl

# Create non-root user
RUN addgroup -g 1000 relay && \
    adduser -D -u 1000 -G relay relay

# Create data directory for SQLite database
RUN mkdir -p /data && \
    chown -R relay:relay /data

WORKDIR /app

# Copy the release from the builder stage
COPY --from=builder --chown=relay:relay /app/_build/prod/rel/metadata_relay ./

# Copy entrypoint script
COPY --chown=relay:relay docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

# Set environment
ENV MIX_ENV=prod
ENV PORT=4001

# Switch to non-root user
USER relay

# Expose the port
EXPOSE 4001

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:4001/health || exit 1

# Run the application with automatic migrations
CMD ["/app/docker-entrypoint.sh"]
