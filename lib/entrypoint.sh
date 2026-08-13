#!/usr/bin/env bash
#
# External URLs referenced below:
#   https://claude.ai/install.sh                — Claude Code installer (downloaded to file, never piped to sh)
#   http://$OLLAMA_HOST:$OLLAMA_PORT/api/tags    — host Ollama server, queried to build opencode's provider config
#   https://opencode.ai/config.json              — $schema referenced in the generated opencode.json
#   https://router.requesty.ai/v1                — Requesty API base URL, written into opencode's provider config
#   https://router.requesty.ai/v1/models          — queried (with the API key) to build opencode's Requesty model list
#
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

# Configure opencode's providers. Config lives under /root/.config, which
# isn't a persisted volume, so this runs unconditionally on every fresh
# container — nothing worth keeping across recreation lives there, and
# rebuilding picks up whatever's currently available instead of going stale.
# enabled_providers is built up explicitly from whichever of the below are
# actually configured, so opencode's model picker stays limited to those even
# if credentials for another provider (e.g. from `opencode auth login`) show
# up later under /root/.local/share/opencode.
OPENCODE_CONFIG="/root/.config/opencode/opencode.json"
if [ ! -f "$OPENCODE_CONFIG" ]; then
    OPENCODE_JSON='{"$schema": "https://opencode.ai/config.json", "enabled_providers": [], "provider": {}}'

    # Ollama (host). OLLAMA_HOST/OLLAMA_PORT come from the host's .env via -e
    # on `podman run`, defaulting to host.containers.internal:11434 —
    # Podman's pasta network backend maps the host to that address (a
    # link-local address, expected to fall outside whatever LAN_BLOCK_RANGE
    # the firewall enforces) as long as Ollama is listening on more than just
    # 127.0.0.1 on the host. Ollama isn't a provider opencode/models.dev
    # already knows about, so its model list has to be queried and built by
    # hand here. If Ollama isn't reachable at container-start time, this is
    # skipped rather than writing a provider that will just fail; rerun
    # `opencode` setup manually once it's up.
    OLLAMA_URL="http://${OLLAMA_HOST:-host.containers.internal}:${OLLAMA_PORT:-11434}"
    TAGS=$(curl -fsSL -m 2 "$OLLAMA_URL/api/tags" 2>/dev/null || true)
    if [ -n "$TAGS" ]; then
        echo ">>> Configuring opencode for Ollama at $OLLAMA_URL..."
        OPENCODE_JSON=$(echo "$OPENCODE_JSON" | jq --arg url "$OLLAMA_URL/v1" --argjson tags "$TAGS" '
            .enabled_providers += ["ollama"] |
            .provider.ollama = {
              npm: "@ai-sdk/openai-compatible",
              name: "Ollama (host)",
              options: { baseURL: $url },
              models: ( [ $tags.models[] | select((.capabilities // []) | index("tools")) | .model ]
                        | reduce .[] as $m ({}; . + {($m): {name: $m}}) )
            }')
    else
        echo ">>> Ollama not reachable at $OLLAMA_URL, skipping opencode Ollama provider config"
    fi

    # Requesty (router.requesty.ai), a hosted LLM router/gateway — optional,
    # only configured if REQUESTY_API_KEY is set in the host's .env. Requesty
    # is a provider opencode/models.dev already knows about, but that static
    # entry lists Requesty's whole public catalog (hundreds of models),
    # unfiltered by org policy. Requesty's own /v1/models endpoint is
    # access-scoped by the auth header instead: called with a Requesty API
    # key it returns only that key's approved models (its access list, else
    # its group, else the org's approved set); called with no key it returns
    # the same unfiltered public catalog opencode's static entry has. So the
    # model list is queried and built by hand here from the authenticated
    # response, the same way Ollama's is above, rather than left to
    # opencode's built-in (unscoped) discovery. apiKey is still written as
    # the literal string "{env:REQUESTY_API_KEY}", which opencode expands
    # from its own process environment at runtime — the key value itself
    # never touches disk in opencode.json, only this curl call's header.
    if [ -n "${REQUESTY_API_KEY:-}" ]; then
        REQUESTY_MODELS=$(curl -fsSL -m 5 "https://router.requesty.ai/v1/models" \
            -H "Authorization: Bearer $REQUESTY_API_KEY" 2>/dev/null || true)
        if [ -n "$REQUESTY_MODELS" ]; then
            echo ">>> Configuring opencode for Requesty..."
            OPENCODE_JSON=$(echo "$OPENCODE_JSON" | jq --argjson models "$REQUESTY_MODELS" '
                .enabled_providers += ["requesty"] |
                .provider.requesty = {
                  options: { baseURL: "https://router.requesty.ai/v1", apiKey: "{env:REQUESTY_API_KEY}" },
                  models: ( [ $models.data[] | select(.supports_tool_calling) | .id ]
                            | reduce .[] as $m ({}; . + {($m): {name: $m}}) )
                }')
        else
            echo ">>> Requesty API not reachable, skipping opencode Requesty provider config"
        fi
    fi

    if [ "$(echo "$OPENCODE_JSON" | jq '.enabled_providers | length')" -gt 0 ]; then
        mkdir -p "$(dirname "$OPENCODE_CONFIG")"
        echo "$OPENCODE_JSON" > "$OPENCODE_CONFIG"
    fi
fi

# Seed environment notes for both agents (created once; edit in place
# afterwards). Notes arrive via a read-only bind mount at /etc/dev-env-notes
# that the host populates from $ENV_NOTES — same source as --update-notes,
# so the two can't drift, and the text never passes through shell parsing.
[ -f /root/.claude/CLAUDE.md ] || cp /etc/dev-env-notes /root/.claude/CLAUDE.md
[ -f /root/.codex/AGENTS.md ]  || cp /etc/dev-env-notes /root/.codex/AGENTS.md

exec "$@"
