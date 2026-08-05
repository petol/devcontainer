#!/usr/bin/env bash
set -e
export PATH="/root/.local/bin:$PATH"
STAMP="/root/.claude/.installed"

if [ ! -f "$STAMP" ]; then
    echo ">>> Installing Claude Code..."
    INSTALLER=$(mktemp /tmp/claude-install-XXXXXX.sh)
    chmod 0600 "$INSTALLER"
    # Download installer to file — never pipe directly into sh
    curl -fsSL https://claude.ai/install.sh -o "$INSTALLER"
    # Basic sanity checks: must be a shell script and non-trivially sized
    if ! head -1 "$INSTALLER" | grep -q '^#!'; then
        echo ">>> Error: installer does not look like a shell script" >&2
        rm -f "$INSTALLER"
        exit 1
    fi
    if [ ! -s "$INSTALLER" ] || [ "$(wc -c < "$INSTALLER")" -lt 1000 ]; then
        echo ">>> Error: installer is unexpectedly small" >&2
        rm -f "$INSTALLER"
        exit 1
    fi
    # Log the hash so the caller can audit what ran
    echo ">>> installer SHA256: $(sha256sum "$INSTALLER" | cut -d' ' -f1)"
    chmod 0700 "$INSTALLER"
    "$INSTALLER"
    rm -f "$INSTALLER"
    touch "$STAMP"
fi

# Keep .claude.json inside the persisted volume
if [ ! -f "/root/.claude/.claude.json" ]; then
    cp /root/.claude.json /root/.claude/.claude.json 2>/dev/null || true
fi
ln -sf /root/.claude/.claude.json /root/.claude.json

# Codex CLI — binary lives in the persisted /root/.local volume, auth in /root/.codex
if [ ! -x "/root/.local/bin/codex" ]; then
    echo ">>> Installing Codex CLI..."
    npm install -g --prefix /root/.local @openai/codex
fi

# opencode — binary lives in the persisted /root/.local volume, same as Codex
if [ ! -x "/root/.local/bin/opencode" ]; then
    echo ">>> Installing opencode..."
    npm install -g --prefix /root/.local opencode-ai
fi

# `-x` on the symlink above only proves the target file has the executable
# bit set, not that opencode-ai's postinstall actually copied a working
# binary into place (seen failing once already, seemingly a network race at
# container start). Verify it actually runs, and if not, rerun postinstall
# directly rather than leaving a broken `opencode` for the user to debug.
if ! /root/.local/bin/opencode --version >/dev/null 2>&1; then
    echo ">>> opencode binary looks broken, rerunning its postinstall..."
    node /root/.local/lib/node_modules/opencode-ai/postinstall.mjs
fi

# Point opencode at the host's Ollama server. OLLAMA_HOST/OLLAMA_PORT come
# from the host's .env via -e on `podman run`, defaulting to
# host.containers.internal:11434 — Podman's pasta network backend maps the
# host to that address (a link-local address, expected to fall outside
# whatever LAN_BLOCK_RANGE the firewall enforces) as long as Ollama is
# listening on more than just 127.0.0.1 on the host. Config lives under
# /root/.config, which isn't a persisted volume, so this runs unconditionally
# on every fresh container — nothing worth keeping
# across recreation lives there, and re-querying picks up whatever models are
# currently pulled on the host instead of going stale. If Ollama isn't
# reachable at container-start time, this is skipped rather than writing a
# provider that will just fail; rerun `opencode` setup manually once it's up.
OPENCODE_CONFIG="/root/.config/opencode/opencode.json"
if [ ! -f "$OPENCODE_CONFIG" ]; then
    OLLAMA_URL="http://${OLLAMA_HOST:-host.containers.internal}:${OLLAMA_PORT:-11434}"
    TAGS=$(curl -fsSL -m 2 "$OLLAMA_URL/api/tags" 2>/dev/null || true)
    if [ -n "$TAGS" ]; then
        echo ">>> Configuring opencode for Ollama at $OLLAMA_URL..."
        mkdir -p "$(dirname "$OPENCODE_CONFIG")"
        echo "$TAGS" | jq --arg url "$OLLAMA_URL/v1" '
            {
              "$schema": "https://opencode.ai/config.json",
              enabled_providers: ["ollama"],
              provider: {
                ollama: {
                  npm: "@ai-sdk/openai-compatible",
                  name: "Ollama (host)",
                  options: { baseURL: $url },
                  models: ( [ .models[] | select((.capabilities // []) | index("tools")) | .model ]
                            | reduce .[] as $m ({}; . + {($m): {name: $m}}) )
                }
              }
            }' > "$OPENCODE_CONFIG"
    else
        echo ">>> Ollama not reachable at $OLLAMA_URL, skipping opencode Ollama provider config"
    fi
fi

# Seed environment notes for both agents (created once; edit in place
# afterwards). Notes arrive via a read-only bind mount at /etc/dev-env-notes
# that the host populates from $ENV_NOTES — same source as --update-notes,
# so the two can't drift, and the text never passes through shell parsing.
[ -f /root/.claude/CLAUDE.md ] || cp /etc/dev-env-notes /root/.claude/CLAUDE.md
[ -f /root/.codex/AGENTS.md ]  || cp /etc/dev-env-notes /root/.codex/AGENTS.md

exec "$@"
