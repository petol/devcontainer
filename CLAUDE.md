# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single Bash script (`dev`) that defines a Podman-based dev container for agentic/"yolo mode" AI coding on a NixOS host. There is no build system, no test suite, no package.json/Makefile — the entire project is `dev`, plus `README.md` and `LICENSE`. The Dockerfile and the container's entrypoint script both live inline as heredocs inside `dev`, not as separate files.

## Commands

- `bash -n dev` — syntax-check after any edit. There is no other linter.
- `dev --rebuild` — rebuild the image and pick up changes to `build_image()` or the entrypoint. Required after editing either.
- `dev --flush --rebuild` — full reset: wipes `claude-auth`, `claude-local`, `codex-auth` (not `dev-audit`) and rebuilds. Use this when you need to verify an install-on-first-run code path actually executes — a stale volume with a manually-placed binary will otherwise make an install check silently pass without ever running (this exact bug happened once with the Codex binary).
- `dev --upgrade` — reinstall Claude Code, Codex, and opencode, preserving auth.
- `dev --restart <path>` — stop/remove the running container first, so a fresh one is created mounting `<path>`, instead of just attaching to whatever is already running with its old mount.
- `dev --update-notes` — force-rewrite the seeded `CLAUDE.md`/`AGENTS.md` from the current template without flushing auth. Writes straight to each volume's mountpoint, so it works even if no container is running.
- No automated tests exist. The established way to validate a change to `dev` is to run the equivalent commands live inside the *currently running* container first (pacman installs, capability checks, nft rule syntax, etc.), confirm the behavior, and only then write it into the Dockerfile/entrypoint heredoc. Several past changes (Playwright/Chromium, the network firewall, the `--upgrade` volume-inspect fix) were verified this way before being committed.

## Architecture

Everything is in `dev`, in four parts:

1. **Flag parsing** (`--rebuild`/`--flush`/`--upgrade`/`--restart`/`--update-notes`/`--help`) at the top.
2. **`build_image()`** — the Dockerfile as a heredoc. Installs the Arch toolchain, Oh My Zsh, Chromium (system libs only — see gotcha below), and Playwright globally.
3. **`ENTRYPOINT_SCRIPT`** — a heredoc written to a temp file and bind-mounted into the container as `/entrypoint.sh`. Runs once per container creation: installs Claude Code (stamped via `/root/.claude/.installed` so it never reruns), installs Codex if its binary is missing, installs opencode if its binary is missing, generates opencode's Ollama provider config from whatever the host currently has pulled (see gotcha below), and seeds `CLAUDE.md`/`AGENTS.md` environment notes into the two auth volumes (only if not already present — see gotcha below).
4. **Attach-or-start logic** at the bottom, which now follows a specific two-step container lifecycle (see below).

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

`ENV_NOTES` is defined exactly once in `dev` (outside `ENTRYPOINT_SCRIPT`). The entrypoint heredoc contains a literal `ENV_NOTES_PLACEHOLDER` token that gets swapped for the real text via `${ENTRYPOINT_SCRIPT//ENV_NOTES_PLACEHOLDER/$ENV_NOTES}` after the heredoc is captured — this is why the entrypoint heredoc stays single-quoted (`'EOF'`, no shell expansion) while still picking up the shared content; the alternative (an unquoted heredoc) would require escaping every `$INSTALLER`/`$STAMP`/`$(...)` the entrypoint uses internally.

On first container start, the entrypoint writes `CLAUDE.md`/`AGENTS.md` into `claude-auth`/`codex-auth` only if the file doesn't already exist (`[ -f ... ] || echo ... > ...`), so user edits inside a running container are never clobbered by a later restart. To pick up template changes without touching auth, run `dev --update-notes` — it writes `$ENV_NOTES` straight to each volume's host-side mountpoint (found via `podman volume inspect --format '{{.Mountpoint}}'`, same trick `--upgrade` uses), so it works whether or not the container is currently running, and does not require `--flush`/reauth.

### Networking backend: pasta, not host networking

Rootless Podman here uses **pasta** by default, which clones the host's outbound interface's *name and IP* into the container's own private network namespace for transparent, NAT-free access. From inside the container, `ip addr` looks identical to host networking (same interface name, same IP) — it isn't. Confirm with `ip -d link show <iface>`: a pasta interface shows up as `tun type tap`, with a sysfs path under `/sys/devices/virtual/net/...` and a synthetic gateway MAC in the ARP table, whereas real host networking would not create a new namespace at all. This has been misdiagnosed as `--network=host` once already in this project — check before assuming either way.

### opencode + Ollama: reachable via pasta's host.containers.internal, no firewall change needed

opencode is configured to talk to Ollama running on the host, not inside the container — there's no Ollama install in the Dockerfile. This works because pasta (see above) maps the host to `host.containers.internal`/`host.docker.internal` (both resolve to the same link-local address, `169.254.1.2` here) automatically, no `containers.conf` changes required. That address is outside `192.168.0.0/16`, so the LAN-block firewall rule doesn't touch it — confirmed working (`curl http://host.containers.internal:11434/api/tags` from inside the container) without adding an nft exception. The one host-side requirement is that Ollama listens on more than just `127.0.0.1`; if the entrypoint's `curl` to `/api/tags` fails at container-start time (Ollama down, or bound to loopback only), it just skips writing the provider config rather than seeding a broken one.

The generated config only lists models with `tools` in their Ollama `capabilities` (filters out embedding-only models like `nomic-embed-text`), since opencode needs tool-calling for agentic use.

### Threat model for the yolo-mode hardening

Everything in the container still runs as root. The capability pin (`--cap-drop=ALL` + explicit minimal `--cap-add`), memory/pids limits, and the audit log are best-effort hardening against a careless agent or a prompt-injection-driven mistake — not guarantees against a deliberately adversarial one, since root-in-container has other avenues regardless. The one piece that *is* a hard guarantee is the network rule, specifically because of the two-container split described above: the capability needed to remove it is never available to anything the agent can reach.
