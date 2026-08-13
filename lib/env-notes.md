# Environment

You are running inside a persistent Podman dev container (Arch Linux), started
via the `dev` script — not directly on the host.

- Host OS: NixOS (host packages are managed via Nix, not pacman/apt — this
  container's package manager has no bearing on the host)
- Container OS: Arch Linux (pacman available inside the container)
- Shell: zsh
- GitHub identity:
  - Username: `{{GITHUB_USERNAME}}`
  - Commit email: `{{GITHUB_EMAIL}}`
- You may install packages with `pacman` as needed. The container is ephemeral,
  so system packages installed this way disappear when it is recreated.
- Workspace: the host project dir is bind-mounted at `/code` — the only path
  shared with the host
- `/code` may map to different host folders between runs. Do not assume a
  particular path under `/code` always represents the same project; determine
  project identity from the folder's contents. Keep project-specific memories,
  notes, and configuration in that project's folder rather than associating
  them globally with a `/code` path.
- Persistent volumes (survive container restarts/recreation, wiped only by
  `dev --flush`):
  - `/root/.claude` — Claude Code auth + config
  - `/root/.codex` — Codex CLI auth + config
  - `/root/.local` — installed CLI binaries (claude, codex, opencode) and
    global npm/pip/go installs
- Anything outside `/code` and the volumes above is ephemeral and resets on
  container recreation — this includes `/root/.config/opencode/opencode.json`
  (see below), so edits there don't survive a container recreation.
- opencode is installed alongside Claude Code and Codex. It's pre-configured
  with an `ollama` provider pointing at the Ollama server running on the
  host, reachable at `{{OLLAMA_HOST}}:{{OLLAMA_PORT}}` via Podman's pasta
  networking — no LAN-block or extra setup needed. That provider's model
  list is generated at container-start time from whatever's actually pulled
  on the host (`ollama list` there), so it reflects that host's models, not
  a fixed set.
- If `REQUESTY_API_KEY` was set in the host's `.env`, opencode is also
  pre-configured with a `requesty` provider (router.requesty.ai). Like the
  Ollama list above, its model list is queried at container-start time (from
  Requesty's own `/v1/models`, authenticated with the key) and limited to
  whatever models that Requesty org/key has approved, not opencode's static,
  unscoped catalog of every Requesty model.
- This container is deliberately permissive (built for agentic/"yolo mode"
  use) since it's isolated from the host — but it is hardened in specific,
  deliberate ways, listed below. If something fails because of one of these,
  that is by design, not a bug to work around:
  - Network: outbound to the home LAN (`{{LAN_BLOCK_RANGE}}`) is blocked
    except the DNS server (`{{DNS_IP}}`). General internet access is open —
    this is not an allowlist, just a LAN block. Enforced by an nftables rule
    in this container's own network namespace.
  - Capabilities: pinned to a minimal explicit set (no `NET_ADMIN`,
    `NET_RAW`, etc.). Commands like `ping`, `nft`, `ip route add/del`, or
    anything needing raw sockets will fail with "Operation not permitted" —
    that's the capability pin working, not a broken container.
  - Resources: memory capped at 24GB, process count capped at 4096 pids.
  - Audit: interactive shell commands (typed at this zsh prompt) are logged
    to `/root/.audit/shell-history.log`. This does not cover Claude/Codex's
    own tool-invoked commands, which each already logs separately in its own
    persisted state.
