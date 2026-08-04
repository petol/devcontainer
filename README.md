# devcontainer

A Podman-based dev container for AI-assisted coding on NixOS, driven by a single `dev` script. No per-project config files, no home dir pollution.

## What it does

- Spins up a persistent Arch Linux container with a curated toolchain, including headless Chromium via Playwright
- Installs Claude Code, Codex CLI, and opencode on first run, auth persists across rebuilds via named volumes
- opencode is pre-configured to use Ollama running on the host as a model provider — see [Local models via Ollama](#local-models-via-ollama)
- Seeds both agents with a `CLAUDE.md`/`AGENTS.md` note describing the container so you don't have to re-explain the setup every session
- Mounts only the current project directory — nothing else is visible inside the container
- Hardened for agentic/"yolo mode" use: LAN access is blocked (internet stays open), capabilities are pinned to a minimal explicit set, memory/process limits are enforced, and interactive shell commands are logged — see [Security hardening](#security-hardening)
- Re-attaches to a running container if one is already active
- Installers are fetched from official sources, if you're sensitive to curl | sh then review first

## Install

```bash
git clone <repo-url> ~/code/devcontainer
ln -s ~/code/devcontainer/dev ~/.local/bin/dev
chmod +x ~/code/devcontainer/dev
```

Make sure `~/.local/bin` is in your PATH. If not, add to your `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

`dev` locates its supporting files (`lib/Containerfile`, `lib/entrypoint.sh`, `lib/env-notes.md`) relative to its own real path, so the repo checkout needs to stay intact as a unit — don't move or symlink `dev` on its own separately from the rest of the clone.

## Usage

```bash
dev                    # mount current directory
dev ~/code/myproject   # mount a specific project
dev --rebuild          # force image rebuild (e.g. after editing dev script)
dev --flush            # remove persistent auth/binary volumes (not the audit log)
dev --upgrade          # reinstall claude code, codex, and opencode, preserve auth
dev --restart          # stop/remove the running container so a new one is
                       # created (e.g. to mount a different project) instead
                       # of just attaching to the old one
dev --update-notes     # rewrite the seeded CLAUDE.md/AGENTS.md from the
                       # current template, without flushing auth
dev --help             # show usage
```

Flags can be combined in any order:

```bash
dev --flush --rebuild ~/code/myproject
```

## How it works

`dev` is the orchestrator; the Arch Linux image, entrypoint, and env-notes content live alongside it in `lib/`:

- **Image definition** — the Arch Linux base image and toolchain is defined in `lib/Containerfile`
- **Entrypoint logic** — `lib/entrypoint.sh` runs Claude Code, Codex CLI, and opencode installation on first container start, each gated so it never reruns once done; environment notes are seeded into both agents' config the same way
- **Container startup** — the container starts detached (not attached to your terminal), a short-lived helper container then installs the network firewall rule (see below), and only then does `dev` attach you to an interactive shell. Both a first-ever start and reattaching to an already-running container go through that same final attach step.
- **Named volumes** — `claude-auth`, `claude-local`, `codex-auth`, and `dev-audit` persist auth, binaries, and the shell audit log across container restarts and rebuilds (see [Volumes](#volumes))
- **Auth persistence** — `.claude.json` is symlinked into the `claude-auth` volume so auth survives container rebuilds

## Installed toolchain

- `base-devel`, `git`, `curl`, `wget`, `unzip`
- `nodejs`, `npm`, `python`, `python-pip`, `go`
- `zsh` + Oh My Zsh
- `chromium` (system libraries only) + Playwright, for headless browser testing — see [Headless browser testing](#headless-browser-testing)

## Local models via Ollama

If Ollama is running on the host, opencode is auto-configured to use it as a model provider — no setup needed. On every fresh container start, the entrypoint queries the host's Ollama server at `http://host.containers.internal:11434` (reachable automatically via Podman's pasta networking, no firewall changes needed) and writes an `ollama` provider into `~/.config/opencode/opencode.json`, listing whatever tool-capable models are currently pulled on the host.

Requirements on the host side:

- Ollama must be listening on more than just `127.0.0.1` (e.g. `OLLAMA_HOST=0.0.0.0` before starting it), since traffic arrives via the container's pasta interface, not the host's own loopback.
- If Ollama isn't reachable when the container starts, this step is skipped silently — start Ollama and recreate the container (`dev --restart`), or configure `~/.config/opencode/opencode.json` by hand.

This config file isn't in a persisted volume, so it's regenerated fresh (picking up any newly pulled models) every time the container is recreated, rather than going stale like a one-time seed would.

## Updating the toolchain

Edit `lib/Containerfile`, then rebuild:

```bash
dev --rebuild
```

## Upgrading Claude Code, Codex, and opencode

To upgrade all three without losing auth:

```bash
dev --upgrade
```

## Headless browser testing

Playwright is installed globally, and its own version-matched Chromium build is pre-fetched at image-build time. `require('playwright')` resolves from anywhere via `NODE_PATH`, no local install needed. The system `chromium` package isn't used directly as the browser — it's there purely to provide the shared libraries (nss, gtk3, alsa-lib, mesa, ...) that Playwright's downloaded browser needs to actually run.

## Security hardening

This container runs Claude Code / Codex in "yolo mode" (no per-command confirmation), so it's hardened against a careless agent or a prompt-injection-driven mistake — not against a deliberately adversarial one, since everything still runs as root inside the container's own namespaces.

- **Network**: outbound access to the home LAN (`192.168.0.0/16`) is blocked except the DNS server. General internet access stays open — this is a LAN block, not an allowlist. The rule is installed by a short-lived helper container that transiently joins the main container's network namespace with `NET_ADMIN`; the main container itself never gets that capability, so nothing running inside it — including the agent — has a way to remove the rule. This is a real, kernel-enforced boundary, not just a convention.
- **Capabilities**: pinned to an explicit minimal set (`--cap-drop=ALL` + a small `--cap-add` list) instead of relying on Podman's implicit default, so a future Podman version widening its defaults doesn't silently widen this container's too.
- **Resources**: memory and process-count limits act as a backstop against a runaway process (fork bomb, OOM) taking down the host.
- **Audit log**: interactive shell commands (typed at the zsh prompt) are logged to the persisted `dev-audit` volume. This covers manual shell use specifically — Claude Code's and Codex's own tool-invoked commands aren't typed at an interactive prompt, but each CLI already keeps its own durable session/history log in its respective auth volume.

## Volumes

| Volume | Mounted at | Purpose |
|---|---|---|
| `claude-auth` | `/root/.claude` | Claude Code auth, config, and install stamp |
| `claude-local` | `/root/.local` | Claude Code, Codex CLI, and opencode binaries |
| `codex-auth` | `/root/.codex` | Codex CLI auth and config |
| `dev-audit` | `/root/.audit` | Interactive shell command audit log |

To wipe auth and binaries and start fresh (this does **not** remove `dev-audit`):

```bash
dev --flush
```
