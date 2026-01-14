FROM rust:latest as builder

WORKDIR /usr/src/app

# Copy necessary files
# Context is expected to be `native/`
COPY mydia_p2p_core ./mydia_p2p_core
COPY mydia_p2p_e2e ./mydia_p2p_e2e

# Build dependencies
WORKDIR /usr/src/app/mydia_p2p_e2e
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/src/app/mydia_p2p_e2e/target/release/mydia_p2p_e2e /usr/local/bin/mydia-e2e
ENV RUST_LOG=info
ENTRYPOINT ["mydia-e2e"]
