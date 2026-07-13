# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single Bash script (`dev`) that defines a Podman-based dev container for agentic/"yolo mode" AI coding on a NixOS host. There is no build system, no test suite, no package.json/Makefile — the entire project is `dev`, plus `README.md` and `LICENSE`. The Dockerfile and the container's entrypoint script both live inline as heredocs inside `dev`, not as separate files.

## Commands

- `bash -n dev` — syntax-check after any edit. There is no other linter.
- `dev --rebuild` — rebuild the image and pick up changes to `build_image()` or the entrypoint. Required after editing either.
- `dev --flush --rebuild` — full reset: wipes `claude-auth`, `claude-local`, `codex-auth` (not `dev-audit`) and rebuilds. Use this when you need to verify an install-on-first-run code path actually executes — a stale volume with a manually-placed binary will otherwise make an install check silently pass without ever running (this exact bug happened once with the Codex binary).
- `dev --upgrade` — reinstall Claude Code and Codex, preserving auth.
- No automated tests exist. The established way to validate a change to `dev` is to run the equivalent commands live inside the *currently running* container first (pacman installs, capability checks, nft rule syntax, etc.), confirm the behavior, and only then write it into the Dockerfile/entrypoint heredoc. Several past changes (Playwright/Chromium, the network firewall, the `--upgrade` volume-inspect fix) were verified this way before being committed.

## Architecture

Everything is in `dev`, in four parts:

1. **Flag parsing** (`--rebuild`/`--flush`/`--upgrade`/`--help`) at the top.
2. **`build_image()`** — the Dockerfile as a heredoc. Installs the Arch toolchain, Oh My Zsh, Chromium (system libs only — see gotcha below), and Playwright globally.
3. **`ENTRYPOINT_SCRIPT`** — a heredoc written to a temp file and bind-mounted into the container as `/entrypoint.sh`. Runs once per container creation: installs Claude Code (stamped via `/root/.claude/.installed` so it never reruns), installs Codex if its binary is missing, and seeds `CLAUDE.md`/`AGENTS.md` environment notes into the two auth volumes (only if not already present — see gotcha below).
4. **Attach-or-start logic** at the bottom, which now follows a specific two-step container lifecycle (see below).

### Container lifecycle: detached + exec, plus a throwaway firewall helper

The main container starts detached (`podman run -d ... sleep infinity`), not in the foreground. A second, `--rm` throwaway container then runs `podman run --rm --network container:$CONTAINER --cap-add=NET_ADMIN "$IMAGE" sh -c 'nft ...'` — it joins the *main* container's existing network namespace instead of getting its own, installs the LAN-blocking firewall rule there, and exits immediately. Only then does the script attach interactively via `podman exec -it -w /code "$CONTAINER" /bin/zsh` — the same call already used by the "reattach to an already-running container" branch, so both paths converge.

This exists specifically so the main container never has to hold `NET_ADMIN` itself: the firewall rule is installed by a process that has the capability only transiently, while the interactive session (and anything Claude/Codex runs in yolo mode) never gets it. That's a real kernel-enforced boundary, not a convention — verify it by checking `capsh --print` inside the container for the absence of `cap_net_admin`, and confirming `nft list ruleset` fails with "Operation not permitted" from inside.

### Volumes — names are not fully self-explanatory

| Volume | Mounted at | Actually contains |
|---|---|---|
| `claude-auth` | `/root/.claude` | Claude auth/config + the `.installed` stamp that gates reinstall |
| `claude-local` | `/root/.local` | **Both** the Claude *and* Codex binaries, despite the name |
| `codex-auth` | `/root/.codex` | Codex auth/config only — no install stamp lives here |
| `dev-audit` | `/root/.audit` | Interactive shell history log (zsh `preexec` hook) |

Codex's reinstall check is `[ ! -x /root/.local/bin/codex ]` against `claude-local`, not a stamp file in `codex-auth` — there is no such stamp. A previous version of `--upgrade` tried to clear one anyway; it was dead code and has been removed. If you're touching the upgrade/flush logic, remember which volume actually gates which install.

### Environment notes are seeded once, not synced

The entrypoint writes `CLAUDE.md`/`AGENTS.md` into `claude-auth`/`codex-auth` only if the file doesn't already exist (`[ -f ... ] || echo ... > ...`), so user edits inside a running container are never clobbered. The tradeoff: editing the heredoc template in `dev` does **not** update files already seeded into an existing container's volumes — those have to be edited directly too, or the volume flushed. When updating the environment-notes content, keep the heredoc in `dev` and the two live files in sync manually.

### Networking backend: pasta, not host networking

Rootless Podman here uses **pasta** by default, which clones the host's outbound interface's *name and IP* into the container's own private network namespace for transparent, NAT-free access. From inside the container, `ip addr` looks identical to host networking (same interface name, same IP) — it isn't. Confirm with `ip -d link show <iface>`: a pasta interface shows up as `tun type tap`, with a sysfs path under `/sys/devices/virtual/net/...` and a synthetic gateway MAC in the ARP table, whereas real host networking would not create a new namespace at all. This has been misdiagnosed as `--network=host` once already in this project — check before assuming either way.

### Threat model for the yolo-mode hardening

Everything in the container still runs as root. The capability pin (`--cap-drop=ALL` + explicit minimal `--cap-add`), memory/pids limits, and the audit log are best-effort hardening against a careless agent or a prompt-injection-driven mistake — not guarantees against a deliberately adversarial one, since root-in-container has other avenues regardless. The one piece that *is* a hard guarantee is the network rule, specifically because of the two-container split described above: the capability needed to remove it is never available to anything the agent can reach.
