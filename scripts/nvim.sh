#!/bin/bash
set -euo pipefail

# RESP: Wrote the full harness below. It does three things beyond the temp dirs:
#   (1) builds + runs the sidekick server from the working tree (needs :8000),
#   (2) generates a throwaway init that loads ONLY nvim/init.lua from this repo,
#       pointed at the repo as a local marketplace (path = REPO_ROOT),
#   (3) launches `nvim --clean -u <init>` so your personal config is skipped.
# I extended your EXIT trap to also kill the server. NOTE: this only runs once
# the init.lua changes land — it needs the `marketplace.path` option AND the
# else-branch fix (`marketplace = ...`) we discussed; right now that file has a
# parse error so `require("nvim")` would fail. Trim the server bits if you'd
# rather run it yourself.

# Capture your real claude config dir BEFORE we override it below, so we can
# copy your existing login out of it.
REAL_CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Isolated, throwaway config dirs so this harness never touches your personal
# ~/.config/nvim or ~/.claude.
NVIM_CONFIG_DIR="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$(mktemp -d)"
export CLAUDE_CONFIG_DIR   # the plugin-spawned `claude` inherits this

# Repo root = parent of this script's directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PORT=$(( RANDOM % 16384 + 49152 ))

SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$NVIM_CONFIG_DIR" "$CLAUDE_CONFIG_DIR"
}
trap cleanup EXIT

# 1. Build and start the sidekick server from the working tree on $PORT.
go build -C "$REPO_ROOT" -o "$NVIM_CONFIG_DIR/sidekick" .
"$NVIM_CONFIG_DIR/sidekick" --port "$PORT" &
SERVER_PID=$!

# Wait until it accepts connections (any HTTP reply — a 405 on GET / is fine).
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.1
done

cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'EOF'
{
  "permissions": { "defaultMode": "auto" },
  "skipAutoPermissionPrompt": true
}
EOF
if [ -f "$REAL_CLAUDE_DIR/.credentials.json" ]; then
  cp "$REAL_CLAUDE_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
  chmod 600 "$CLAUDE_CONFIG_DIR/.credentials.json"
else
  echo "warn: no $REAL_CLAUDE_DIR/.credentials.json to reuse; claude may prompt to log in" >&2
fi
cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<EOF
{
  "hasCompletedOnboarding": true,
  "theme": "dark",
  "projects": {
    "$REPO_ROOT": { "hasTrustDialogAccepted": true }
  }
}
EOF

# 2. Minimal init that loads ONLY the sidekick plugin, straight from the
#    working tree, pointed at this repo as a local marketplace.
cat > "$NVIM_CONFIG_DIR/init.lua" <<EOF
package.path = "$REPO_ROOT/?/init.lua;" .. package.path
require("nvim").setup({
  server_url = "http://127.0.0.1:$PORT",
  claude = {
    marketplace = { path = "$REPO_ROOT" },
  },
})
EOF

# 3. Launch nvim factory-clean (--clean skips your plugins/config) with our
#    explicit init (-u). Any extra args pass through to nvim. Not `exec`, so the
#    EXIT trap still runs after nvim quits.
nvim --clean -u "$NVIM_CONFIG_DIR/init.lua" "$@"
