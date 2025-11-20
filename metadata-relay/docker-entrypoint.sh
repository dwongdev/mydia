#!/bin/sh
set -e

echo "Running database migrations..."
/app/bin/metadata_relay eval "MetadataRelay.Release.migrate()"

echo "Starting metadata-relay..."
exec /app/bin/metadata_relay start
