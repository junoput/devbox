# devbox

Generic dev VM provisioner. Scripts for building and maintaining Debian 12 LXC dev environments.

## Quick start

```bash
# On fresh Debian 12 LXC as root:
bash <(curl -fsSL https://raw.githubusercontent.com/junoput/devbox/main/setup.sh)
```

## How it works

1. Create fresh Debian 12 LXC on Proxmox
2. Run the one-liner above — installs all base tools, generates GitHub SSH key, clones this repo to `/opt/devbox`
3. Snapshot LXC as `base-dev-ready`
4. Clone snapshot for each project
5. Run `provision.sh` on the clone — pull latest scripts, pick extra tools via wizard

Updates: edit scripts in this repo → push → run `provision.sh` on any VM → `git pull` happens automatically.

## Base tools (setup.sh)

| Tool | Purpose |
|------|---------|
| zsh + oh-my-zsh | shell (autosuggestions, syntax highlighting) |
| tmux | terminal multiplexer |
| neovim | editor |
| git + gh | version control + GitHub CLI |
| ripgrep + fzf | fast search + fuzzy finder |
| jq + yq | JSON/YAML on CLI |
| htop + btop | resource monitoring |
| podman + podman-compose | containers |
| Node.js LTS | runtime (needed by Claude Code) |
| Claude Code | AI coding assistant |
| python3 + pip | scripting |
| direnv | per-project env vars |
| build-essential | gcc, make |

## Optional modules (provision.sh)

| Module | What |
|--------|------|
| `vscode-web` | VS Code in browser (code-server, port 8080) |
| `rust` | rustup, cargo, rust-analyzer, clippy |
| `python-dev` | pyenv, poetry, pipx |
| `c-dev` | cmake, ninja, gdb, valgrind, clangd |

## App environments (provision.sh → apps/)

| App | What |
|-----|------|
| `cluborbit` | Pull all ClubOrbit repos, run dev stack |

## Adding a new module

```bash
# Create modules/mytool.sh with:
# desc: Short description shown in wizard
set -euo pipefail
# ... install commands ...
```

Push to git. Available on all VMs next time they run `provision.sh`.

## LXC layout

| ID | Name | IP | Base |
|----|------|----|------|
| 107 | base-dev | 192.168.66.20 | snapshot: base-dev-ready |
| 108+ | project-specific | 192.168.66.21+ | clone of 107 |

## Changing VM resources

```bash
# On Proxmox host:
pct set <id> --memory 4096 --cores 4
pct reboot <id>
```
