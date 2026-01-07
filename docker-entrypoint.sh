#!/bin/bash
set -e

# Determine if we're running an interactive server or a one-off command
# If no args passed, default to phx.server
if [ $# -eq 0 ]; then
    COMMAND="mix phx.server"
    FULL_SETUP=true
else
    COMMAND="$*"
    FULL_SETUP=false
fi

# Quick commands that don't need any setup
case "$1" in
    sh|bash)
        exec "$@"
        ;;
esac

# Minimal setup for all mix commands
# Only clean exqlite if the NIF was compiled for a different platform (e.g., host vs container)
# This avoids unnecessary recompilation on every container start
NIF_FILE="_build/dev/lib/exqlite/priv/sqlite3_nif.so"
if [ -f "$NIF_FILE" ]; then
    # Check if the NIF is compatible with this container by checking its ELF interpreter
    # Host-compiled NIFs (e.g., NixOS) will have a different interpreter than container NIFs
    if ! ldd "$NIF_FILE" > /dev/null 2>&1; then
        echo "==> Removing incompatible exqlite NIF (compiled for different platform)..."
        rm -rf _build/dev/lib/exqlite
    fi
fi

# Install Hex and Rebar if not already installed (quiet)
if [ ! -d "$MIX_HOME" ] || [ ! -f "$MIX_HOME/rebar" ]; then
    mix local.hex --force --if-missing > /dev/null 2>&1
    mix local.rebar --force > /dev/null 2>&1
fi

# Full setup only for server mode (no args passed)
if [ "$FULL_SETUP" = true ]; then
    echo "==> Starting Mydia development environment..."

    # Install Mix dependencies
    echo "==> Installing dependencies..."
    mix deps.get --only dev

    # Compile exqlite if needed
    if [ -d "deps/exqlite" ] && [ ! -f "_build/dev/lib/exqlite/priv/sqlite3_nif.so" ]; then
        echo "==> Compiling exqlite..."
        mix deps.compile exqlite
    fi

    # Setup database
    echo "==> Setting up database..."
    mix ecto.create --quiet 2>/dev/null || true
    mix mydia.backup_before_migrate
    mix ecto.migrate

    # Install and build assets if needed
    if [ ! -d "assets/node_modules" ] || [ -z "$(ls -A assets/node_modules 2>/dev/null)" ]; then
        echo "==> Installing Node.js dependencies..."
        mix assets.setup
    fi

    if [ ! -d "priv/static/assets" ] || [ -z "$(ls -A priv/static/assets 2>/dev/null)" ]; then
        echo "==> Building assets..."
        mix assets.build
    fi

    # Setup Flutter player
    echo "==> Setting up Flutter player..."
    cd player

    # Install Flutter dependencies
    flutter pub get

    # Run initial code generation if needed
    if [ -f "lib/graphql/schema.graphql.dart" ]; then
        echo "==> GraphQL codegen already exists, skipping initial build..."
    else
        echo "==> Running initial code generation (GraphQL, Riverpod)..."
        flutter pub run build_runner build --delete-conflicting-outputs || true
    fi

    # Start build_runner watch in background
    echo "==> Starting build_runner watch in background..."
    flutter pub run build_runner watch --delete-conflicting-outputs > /tmp/build_runner.log 2>&1 &

    cd ..

    echo "==> Starting Phoenix server..."
fi

exec $COMMAND
