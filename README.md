# devcontainer

A single-file Podman-based dev container for AI-assisted coding on NixOS. No per-project config files, no home dir pollution.

## What it does

- Spins up a persistent Arch Linux container with a curated toolchain
- Installs Claude Code on first run, auth persists across rebuilds via named volumes
- Mounts only the current project directory — nothing else is visible inside the container
- Re-attaches to a running container if one is already active

## Install

```bash
git clone <repo-url> ~/kod/devcontainer
ln -s ~/kod/devcontainer/dev ~/.local/bin/dev
chmod +x ~/kod/devcontainer/dev
```

Make sure `~/.local/bin` is in your PATH. If not, add to your `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

```bash
dev                  # mount current directory
dev ~/kod/myproject  # mount a specific project
dev --rebuild        # force image rebuild (e.g. after editing dev script)
dev --help           # show usage
```

## How it works

Everything lives in the `dev` script:

- **Image definition** — the Arch Linux base image and toolchain is defined inline as a heredoc, no separate `Containerfile` needed
- **Entrypoint logic** — Claude Code installation runs on first container start, stamped so it never runs twice
- **Named volumes** — `claude-auth` and `claude-local` persist Claude Code auth and binaries across container restarts and rebuilds

## Installed toolchain

- `base-devel`, `git`, `curl`, `wget`, `unzip`
- `nodejs`, `npm`, `python`, `python-pip`, `go`
- `zsh` + Oh My Zsh

## Updating the toolchain

Edit the `build_image()` function in `dev`, then rebuild:

```bash
dev --rebuild
```

## Volumes

| Volume | Mounted at | Purpose |
|---|---|---|
| `claude-auth` | `/root/.claude` | Claude Code auth token |
| `claude-local` | `/root/.local` | Claude Code binary |

To wipe auth and start fresh:

```bash
podman volume rm claude-auth claude-local
```
