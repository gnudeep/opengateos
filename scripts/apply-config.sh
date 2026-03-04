#!/usr/bin/env bash
#
# apply-config.sh — Pull latest config from git and apply to the gateway
#
# Usage:
#   ./apply-config.sh [config-file]
#
# Arguments:
#   config-file   Path to config JSON relative to repo root
#                 (default: configs/harvester-gateway.json)
#
# Environment:
#   REPO_DIR      Local clone of the opengateos repo
#                 (default: /opt/opengateos)
#   REPO_URL      Git remote URL (used for initial clone)
#   BRANCH        Git branch to track (default: main)

set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/opengateos}"
BRANCH="${BRANCH:-main}"
CONFIG_FILE="${1:-configs/harvester-gateway.json}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

# Clone repo if it doesn't exist yet
if [ ! -d "$REPO_DIR/.git" ]; then
    if [ -z "${REPO_URL:-}" ]; then
        die "Repo not found at $REPO_DIR and REPO_URL is not set. Set REPO_URL for initial clone."
    fi
    log "Cloning $REPO_URL into $REPO_DIR..."
    git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

# Pull latest changes
log "Pulling latest changes from origin/$BRANCH..."
cd "$REPO_DIR"
git fetch origin "$BRANCH"

LOCAL_HEAD=$(git rev-parse HEAD)
REMOTE_HEAD=$(git rev-parse "origin/$BRANCH")

if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
    log "Already up to date ($(echo "$LOCAL_HEAD" | head -c 8)). Nothing to apply."
    exit 0
fi

git reset --hard "origin/$BRANCH"
log "Updated to $(git rev-parse --short HEAD)"

# Verify config file exists
CONFIG_PATH="$REPO_DIR/$CONFIG_FILE"
if [ ! -f "$CONFIG_PATH" ]; then
    die "Config file not found: $CONFIG_PATH"
fi

# Validate JSON
if ! python3 -c "import json; json.load(open('$CONFIG_PATH'))" 2>/dev/null; then
    die "Invalid JSON in $CONFIG_PATH"
fi

# Apply config via routercli
log "Applying config from $CONFIG_FILE..."
cp "$CONFIG_PATH" /config/candidate/config.json

log "Comparing changes..."
routercli compare || true

log "Committing config..."
routercli commit --comment "GitOps apply: $(git rev-parse --short HEAD) - $(git log -1 --format='%s')"

log "Saving to boot config..."
routercli save

log "Config applied successfully."
