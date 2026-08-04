# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Bash script (`dev`) plus a `lib/` directory that defines a Podman-based dev container for agentic/"yolo mode" AI coding on a NixOS host. There is no build system, no test suite, no package.json/Makefile — the project is `dev`, `lib/Containerfile`, `lib/entrypoint.sh`, `lib/env-notes.md`, plus `README.md` and `LICENSE`. The Dockerfile and the container's entrypoint script used to live inline as heredocs inside `dev`; they were extracted into `lib/` once `dev` grew past ~400 lines (see Architecture below) and are now read from disk at runtime instead.

**Keep this file up to date.** Whenever a change to `dev`/`lib/` alters architecture, behavior, or a documented gotcha, update the relevant section here in the same change — don't leave it to drift. (The `ENV_NOTES_PLACEHOLDER` mechanism described in a previous version of this file was removed from the code well before the doc caught up — don't repeat that.)

## Commands

- `bash -n dev && bash -n lib/entrypoint.sh` — syntax-check after any edit. `lib/entrypoint.sh` is a standalone script now, so it's also independently shellcheck-able (`shellcheck lib/entrypoint.sh`) if you want deeper checks — not mandatory, no CI enforces it.
- `dev --rebuild` — rebuild the image and pick up changes to `lib/Containerfile` or `lib/entrypoint.sh`. Required after editing either.
- `dev --flush --rebuild` — full reset: wipes `claude-auth`, `claude-local`, `codex-auth` (not `dev-audit`) and rebuilds. Use this when you need to verify an install-on-first-run code path actually executes — a stale volume with a manually-placed binary will otherwise make an install check silently pass without ever running (this exact bug happened once with the Codex binary).
- `dev --upgrade` — reinstall Claude Code, Codex, and opencode, preserving auth.
- `dev --restart <path>` — stop/remove the running container first, so a fresh one is created mounting `<path>`, instead of just attaching to whatever is already running with its old mount.
- `dev --update-notes` — force-rewrite the seeded `CLAUDE.md`/`AGENTS.md` from the current template without flushing auth. Writes straight to each volume's mountpoint, so it works even if no container is running.
- No automated tests exist. The established way to validate a change to `dev`/`lib/` is to run the equivalent commands live inside the *currently running* container first (pacman installs, capability checks, nft rule syntax, etc.), confirm the behavior, and only then write it into `lib/Containerfile`/`lib/entrypoint.sh`. Several past changes (Playwright/Chromium, the network firewall, the `--upgrade` volume-inspect fix) were verified this way before being committed.

## Architecture

`dev` is the orchestrator; the Dockerfile, entrypoint, and env-notes content live in `lib/` as real files, read into bash variables at runtime rather than embedded as heredocs (extracted in a refactor once `dev` grew past ~400 lines — the two are functionally identical since all three heredocs were single-quoted, i.e. captured as literal strings with no shell expansion, so moving them to files changed nothing at runtime).

1. **Flag parsing** (`--rebuild`/`--flush`/`--upgrade`/`--restart`/`--update-notes`/`--help`) at the top of `dev`.
2. **`SCRIPT_DIR`/`LIB_DIR` resolution**, near the very top of `dev`, before anything else: `SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" &>/dev/null && pwd)"`. This has to use `readlink -f` rather than a bare `dirname "$0"` because `dev` is normally invoked through the `~/.local/bin/dev` symlink (the standard install method — see README), and a naive `dirname` would resolve to `~/.local/bin` instead of wherever the repo actually is. `LIB_DIR="$SCRIPT_DIR/lib"` is what everything below reads from.
3. **`lib/Containerfile`** — read via `build_image()`, which pipes it into `podman build -t "$IMAGE" - < "$LIB_DIR/Containerfile"` (same "stdin as Dockerfile, empty build context" semantics as before). Installs the Arch toolchain, Oh My Zsh, Chromium (system libs only — see gotcha below), and Playwright globally.
4. **`lib/entrypoint.sh`** — read into the `ENTRYPOINT_SCRIPT` variable (`ENTRYPOINT_SCRIPT="$(cat "$LIB_DIR/entrypoint.sh")"`), which later gets written to a temp file and bind-mounted into the container as `/entrypoint.sh`. Runs once per container creation: installs Claude Code (stamped via `/root/.claude/.installed` so it never reruns), installs Codex if its binary is missing, installs opencode if its binary is missing, generates opencode's Ollama provider config from whatever the host currently has pulled (see gotcha below), and seeds `CLAUDE.md`/`AGENTS.md` environment notes into the two auth volumes (only if not already present — see gotcha below). It's also a real standalone script now (own `#!/usr/bin/env bash` shebang), so `bash -n`/`shellcheck` can check it directly.
5. **Attach-or-start logic** at the bottom of `dev`, which follows a specific two-step container lifecycle (see below).

### Container lifecycle: detached + exec, plus a throwaway firewall helper

`--restart` stops/removes the existing container (if any) right before the attach-or-start check, so that check always finds no container and falls through to creating a fresh one — this is how you swap the mounted workspace without manually killing the container first. Without `--restart`, a running container is always just reattached to, keeping its original mount.

The main container starts detached (`podman run -d ... sleep infinity`), not in the foreground. A second, `--rm` throwaway container then runs `podman run --rm --network container:$CONTAINER --cap-add=NET_ADMIN "$IMAGE" sh -c 'nft ...'` — it joins the *main* container's existing network namespace instead of getting its own, installs the LAN-blocking firewall rule there, and exits immediately. Only then does the script attach interactively via `podman exec -it -w /code "$CONTAINER" /bin/zsh` — the same call already used by the "reattach to an already-running container" branch, so both paths converge.

This exists specifically so the main container never has to hold `NET_ADMIN` itself: the firewall rule is installed by a process that has the capability only transiently, while the interactive session (and anything Claude/Codex runs in yolo mode) never gets it. That's a real kernel-enforced boundary, not a convention — verify it by checking `capsh --print` inside the container for the absence of `cap_net_admin`, and confirming `nft list ruleset` fails with "Operation not permitted" from inside.

### Volumes — names are not fully self-explanatory

| Volume | Mounted at | Actually contains |
|---|---|---|
| `claude-auth` | `/root/.claude` | Claude auth/config + the `.installed` stamp that gates reinstall |
| `claude-local` | `/root/.local` | The Claude, Codex, **and** opencode binaries, despite the name |
| `codex-auth` | `/root/.codex` | Codex auth/config only — no install stamp lives here |
| `dev-audit` | `/root/.audit` | Interactive shell history log (zsh `preexec` hook) |

Codex's and opencode's reinstall checks are `[ ! -x /root/.local/bin/<binary> ]` against `claude-local`, not a stamp file in a dedicated volume — there is no such stamp for either. A previous version of `--upgrade` tried to clear one for Codex anyway; it was dead code and has been removed. If you're touching the upgrade/flush logic, remember which volume actually gates which install.

opencode has no dedicated auth volume either: its `opencode.json` (the Ollama provider config) lives under `/root/.config`, which isn't a persisted volume at all — it's regenerated from scratch on every fresh container by querying the host's Ollama `/api/tags` at container-start time, rather than seeded once like the `CLAUDE.md`/`AGENTS.md` notes below. Any credentials from `opencode auth login` for other providers would land under `/root/.local/share/opencode`, which *is* covered by the `claude-local` volume since that mounts all of `/root/.local`.

### Environment notes: single source, seeded once, force-updatable

`ENV_NOTES` is read from `lib/env-notes.md` once, near the top of `dev` (`ENV_NOTES="$(cat "$LIB_DIR/env-notes.md")"`) — that's the single source of truth for both the entrypoint's first-run seeding and `--update-notes`' forced overwrite, so the two paths can't drift out of sync.

At container-start time, the host writes `$ENV_NOTES` to a tempfile and bind-mounts it read-only into the container at `/etc/dev-env-notes`; `lib/entrypoint.sh` just `cp`s it into place. This is a bind mount, not a string splice into the entrypoint script — the notes text never passes through shell parsing, so it's safe even if it contains characters like apostrophes that would otherwise break a naive splice. (An earlier version of this mechanism did splice `$ENV_NOTES` into a shell string literal inside the entrypoint via a placeholder token; that broke in production the moment the notes text contained an apostrophe, and was replaced by the bind-mount approach in commit `6e0753b`.)

On first container start, the entrypoint writes `CLAUDE.md`/`AGENTS.md` into `claude-auth`/`codex-auth` only if the file doesn't already exist (`[ -f ... ] || cp ...`), so user edits inside a running container are never clobbered by a later restart. To pick up template changes without touching auth, run `dev --update-notes` — it writes `$ENV_NOTES` straight to each volume's host-side mountpoint (found via `podman volume inspect --format '{{.Mountpoint}}'`, same trick `--upgrade` uses), so it works whether or not the container is currently running, and does not require `--flush`/reauth.

### Networking backend: pasta, not host networking

Rootless Podman here uses **pasta** by default, which clones the host's outbound interface's *name and IP* into the container's own private network namespace for transparent, NAT-free access. From inside the container, `ip addr` looks identical to host networking (same interface name, same IP) — it isn't. Confirm with `ip -d link show <iface>`: a pasta interface shows up as `tun type tap`, with a sysfs path under `/sys/devices/virtual/net/...` and a synthetic gateway MAC in the ARP table, whereas real host networking would not create a new namespace at all. This has been misdiagnosed as `--network=host` once already in this project — check before assuming either way.

### opencode + Ollama: reachable via pasta's host.containers.internal, no firewall change needed

opencode is configured to talk to Ollama running on the host, not inside the container — there's no Ollama install in the Dockerfile. This works because pasta (see above) maps the host to `host.containers.internal`/`host.docker.internal` (both resolve to the same link-local address, `169.254.1.2` here) automatically, no `containers.conf` changes required. That address is outside `192.168.0.0/16`, so the LAN-block firewall rule doesn't touch it — confirmed working (`curl http://host.containers.internal:11434/api/tags` from inside the container) without adding an nft exception. The one host-side requirement is that Ollama listens on more than just `127.0.0.1`; if the entrypoint's `curl` to `/api/tags` fails at container-start time (Ollama down, or bound to loopback only), it just skips writing the provider config rather than seeding a broken one.

The generated config only lists models with `tools` in their Ollama `capabilities` (filters out embedding-only models like `nomic-embed-text`), since opencode needs tool-calling for agentic use.

### Threat model for the yolo-mode hardening

Everything in the container still runs as root. The capability pin (`--cap-drop=ALL` + explicit minimal `--cap-add`), memory/pids limits, and the audit log are best-effort hardening against a careless agent or a prompt-injection-driven mistake — not guarantees against a deliberately adversarial one, since root-in-container has other avenues regardless. The one piece that *is* a hard guarantee is the network rule, specifically because of the two-container split described above: the capability needed to remove it is never available to anything the agent can reach.
