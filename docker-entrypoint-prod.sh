#!/bin/sh
set -e

# Default PUID and PGID to 1000 if not set
PUID=${PUID:-1000}
PGID=${PGID:-1000}

echo "
────────────────────────────────────────
    __  ___          ___
   /  |/  /_  ______/ (_)___ _
  / /|_/ / / / / __  / / __ \`/
 / /  / / /_/ / /_/ / / /_/ /
/_/  /_/\__, /\__,_/_/\__,_/
       /____/

────────────────────────────────────────
User UID:    $PUID
User GID:    $PGID
Timezone:    ${TZ:-UTC}
────────────────────────────────────────
"

# Get current UID and GID of mydia user
CURRENT_UID=$(id -u mydia 2>/dev/null || echo 1000)
CURRENT_GID=$(id -g mydia 2>/dev/null || echo 1000)

# Update user and group IDs if they differ
if [ "$PUID" != "$CURRENT_UID" ] || [ "$PGID" != "$CURRENT_GID" ]; then
    echo "Updating mydia user UID:GID to $PUID:$PGID..."

    # Check if target GID is already in use by another group
    EXISTING_GROUP=$(getent group "$PGID" 2>/dev/null | cut -d: -f1)
    if [ -n "$EXISTING_GROUP" ] && [ "$EXISTING_GROUP" != "mydia" ]; then
        echo "  GID $PGID is already in use by group '$EXISTING_GROUP', removing it..."
        # Try multiple deletion methods
        if ! delgroup "$EXISTING_GROUP" 2>/dev/null && \
           ! groupdel "$EXISTING_GROUP" 2>/dev/null && \
           ! sed -i "/^$EXISTING_GROUP:/d" /etc/group 2>/dev/null; then
            echo "  Warning: Could not remove group '$EXISTING_GROUP', will work around it..."
        fi
    fi

    # Check if target UID is already in use by another user
    EXISTING_USER=$(getent passwd "$PUID" 2>/dev/null | cut -d: -f1)
    if [ -n "$EXISTING_USER" ] && [ "$EXISTING_USER" != "mydia" ]; then
        echo "  UID $PUID is already in use by user '$EXISTING_USER', removing it..."
        deluser "$EXISTING_USER" 2>/dev/null || userdel "$EXISTING_USER" 2>/dev/null || true
    fi

    # Try to update existing user/group, or recreate if it fails
    if ! groupmod -g "$PGID" mydia 2>/dev/null; then
        echo "  Recreating group with GID $PGID..."
        deluser mydia 2>/dev/null || true
        delgroup mydia 2>/dev/null || true
        addgroup -g "$PGID" mydia
        adduser -D -u "$PUID" -G mydia mydia
    elif ! usermod -u "$PUID" mydia 2>/dev/null; then
        echo "  Recreating user with UID $PUID..."
        deluser mydia 2>/dev/null || true
        adduser -D -u "$PUID" -G mydia mydia
    fi

    echo "  Successfully set mydia user to UID:GID $PUID:$PGID"
fi

# Ensure critical directories exist and have correct ownership
mkdir -p /config /data /media
chown -R "$PUID:$PGID" /config /data /media /app

# Set timezone if provided
if [ -n "$TZ" ]; then
    if [ -f "/usr/share/zoneinfo/$TZ" ]; then
        ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
        echo "$TZ" > /etc/timezone
        echo "Timezone set to $TZ"
    else
        echo "Warning: Timezone $TZ not found, using UTC"
    fi
fi

echo "────────────────────────────────────────"
echo "Starting Mydia..."
echo "────────────────────────────────────────"

# Execute the main application as the mydia user
exec su-exec mydia "$@"
