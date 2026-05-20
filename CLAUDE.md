# devbox — LLM Operation Guide

Repo: `junoput/devbox`. Scripts for provisioning Debian 12 LXC dev VMs on Proxmox.
All scripts are idempotent — safe to re-run.

## Infrastructure context

```
Proxmox host:  192.168.88.21  (apodemus-hyrcanicus.home.arpa)
LXC subnet:    192.168.66.0/24 (vmbr1, NAT'd)

LXC 107  base-dev        192.168.66.20   snapshot: base-dev-ready
LXC 108  cluborbit-dev   192.168.66.10   ClubOrbit full dev stack
LXC 105  cluborbit-prod  192.168.66.11   ClubOrbit production
```

SSH to Proxmox: `ssh root@192.168.88.21`
SSH to LXC via Proxmox: `ssh root@192.168.88.21 "pct exec <id> -- <cmd>"`
SSH to LXC direct: `ssh -i ~/.ssh/camenzindt_macbook root@192.168.66.<x>`

## Scripts

### setup.sh — Base VM bootstrap

**Run on:** fresh Debian 12 LXC as root  
**How:** `bash <(curl -fsSL https://raw.githubusercontent.com/junoput/devbox/main/setup.sh)`  
**What it installs:** git, gh, zsh + oh-my-zsh + plugins, tmux, neovim, ripgrep, fzf, jq, yq,
htop, btop, node LTS, npm, Claude Code, podman + podman-compose, direnv, python3, build-essential, sqlite3  
**Interactive step:** pauses to generate a GitHub SSH key (ed25519) — prints public key,
waits for user to add it to github.com/settings/keys, then verifies auth  
**To skip interactive step:** pre-generate key with `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""`,
add to GitHub, then run setup.sh (it skips key gen if key exists)  
**Clones repo to:** `/opt/devbox`

### provision.sh — Module wizard

**Run on:** any LXC that has completed setup.sh  
**How:** `bash /opt/devbox/provision.sh` (or re-fetch: `bash <(curl -fsSL .../provision.sh)`)  
**What:** does `git pull` first (picks up latest scripts), shows numbered menu of modules and apps,
runs selected scripts  
**Non-interactive:** pipe selection: `echo "1 3" | bash /opt/devbox/provision.sh`

### modules/vscode-web.sh

**Installs:** code-server (VS Code in browser)  
**Port:** 8080, no auth (LAN only)  
**Access after install:** `http://<vm-ip>:8080`

### modules/rust.sh

**Installs:** rustup, cargo, rust-analyzer, clippy, rustfmt  
**Shell:** adds cargo to PATH via `~/.cargo/env`

### modules/python-dev.sh

**Installs:** pyenv, pipx, poetry  
**Note:** pyenv compiles Python — takes 5-10 min on first `pyenv install`

### modules/c-dev.sh

**Installs:** cmake, ninja, gdb, valgrind, clang, clang-format, clangd, lldb, libasan

### apps/cluborbit.sh — ClubOrbit dev environment

**Run on:** LXC 108 (or any clone of base-dev-ready)  
**How:** `bash /opt/devbox/apps/cluborbit.sh`  
**Also used to update:** re-running pulls latest `dev` branch for all repos and restarts stack  

**Requires:** VM SSH key registered on GitHub (org member or deploy key with write access).
The base snapshot key is `SHA256:13Bux1LuUG+SW3D/Hmg/lTt/HcropYp0nq3s89dkwMM` — already added.

**What it does:**
1. Clones/updates all ClubOrbit repos via SSH to `/opt/dev/workspace/` on `dev` branch:
   - cluborbit, event-planner, confirmo, bulk-buzz, members,
     orbit-dashboard, orbit-telemetry, orbit-backup
2. Runs `deploy/dev/setup.sh --no-pull` — starts full Podman dev stack

**Dev stack layout after install:**
```
/opt/dev/workspace/
  cluborbit/          main app + deploy configs
  members/            members module
  event-planner/      event planner module
  bulk-buzz/          bulk buzz module
  confirmo/           confirmo module
  orbit-dashboard/    orbit admin dashboard
  orbit-telemetry/    telemetry service
  orbit-backup/       backup service
```

**Access:**
- App: `https://192.168.66.10` (self-signed cert, accept warning)
- Keycloak: `https://192.168.66.10/auth/`
- Login: `admin@orbit.local` / `Admin1234!`
- Orbit: `http://orbit-dev.apodemus-flavicollis.home.arpa/backup` (needs /etc/hosts)

**Hot reload:** yes — Vite dev servers with HMR. Edit files in `/opt/dev/workspace/*/` → browser updates automatically.

**Key containers:**
| Container | Role |
|-----------|------|
| proxy | nginx reverse proxy (ports 80/443) |
| dev-shell | main app Vite dev server (hot reload) |
| dev-gateway | API gateway / auth middleware |
| dev-keycloak | Keycloak auth server (slow start ~2min, needs 4GB+ RAM) |
| dev-members-api | Members backend API |
| dev-members-db | Postgres for members |
| dev-event-planner-* | Event planner frontend + API + DB |
| dev-bulk-buzz-* | Bulk buzz frontend + API |
| dev-confirmo-* | Confirmo frontend + backend |
| orbit-telemetry | Telemetry service |
| orbit-dashboard | Dashboard frontend |
| orbit-backup | Backup service |

**Resource requirements:** min 4GB RAM (6GB recommended — Keycloak JVM is heavy)

## Creating a new dev VM from scratch

```bash
# On Proxmox host:
pct clone 107 <newid> --snapname base-dev-ready --hostname <name> --full
pct set <newid> --memory 6144 --cores 2
pct set <newid> --net0 name=eth0,bridge=vmbr1,ip=192.168.66.<x>/24,gw=192.168.66.1
pct start <newid>

# Copy secrets if ClubOrbit VM:
pct exec <src> -- cat /root/.secrets/github-app.env | pct exec <newid> -- bash -c 'mkdir -p /root/.secrets && chmod 700 /root/.secrets && cat > /root/.secrets/github-app.env && chmod 600 /root/.secrets/github-app.env'
pct exec <src> -- cat /root/.secrets/github-app.pem  | pct exec <newid> -- bash -c 'cat > /root/.secrets/github-app.pem && chmod 600 /root/.secrets/github-app.pem'

# Run cluborbit provisioner:
pct exec <newid> -- bash /opt/devbox/apps/cluborbit.sh
```

## Common operations

```bash
# Check all containers on a VM
ssh root@192.168.88.21 "pct exec 108 -- podman ps --format 'table {{.Names}}\t{{.Status}}'"

# Restart a specific container
ssh root@192.168.88.21 "pct exec 108 -- podman restart <name>"

# View container logs
ssh root@192.168.88.21 "pct exec 108 -- podman logs <name> --tail 50"

# Update all repos + restart dev stack
ssh root@192.168.66.10 "git -C /opt/devbox pull && bash /opt/devbox/apps/cluborbit.sh"

# Increase VM memory (live, no reboot)
ssh root@192.168.88.21 "pct set <id> --memory <mb>"

# Take snapshot before risky changes
ssh root@192.168.88.21 "pct snapshot <id> <snapname>"
```

## Adding or updating tools

New tools installed manually on a VM exist **only on that VM**. To make a tool available on all dev VMs, add it to the repo and push:

### Where to add it

| Tool type | Where |
|-----------|-------|
| Core tool needed on every VM | `setup.sh` (in the appropriate install block) |
| Optional/language-specific tool | New file `modules/<tool>.sh` |
| App-specific dependency | `apps/<app>.sh` |

### Steps

1. Add install commands to the right script in `/opt/devbox/` (or locally)
2. Commit and push:
   ```bash
   git -C /opt/devbox add <file>
   git -C /opt/devbox commit -m "feat: add <tool>"
   git -C /opt/devbox push origin main
   ```
3. Apply to existing VMs by re-running the relevant script:
   ```bash
   # For setup.sh additions — re-run is idempotent:
   bash /opt/devbox/setup.sh

   # For a new module:
   bash /opt/devbox/provision.sh   # select module from menu

   # For app script changes:
   bash /opt/devbox/apps/cluborbit.sh
   ```
4. New VMs cloned from `base-dev-ready` snapshot will NOT have the tool until the snapshot is refreshed. To update the base snapshot:
   ```bash
   # On LXC 107 (base-dev):
   bash /opt/devbox/setup.sh
   # Then on Proxmox:
   ssh root@192.168.88.21 "pct snapshot 107 base-dev-ready --description 'updated base'"
   ```

**Tools only installed manually (not added to a script) are lost on next clone or rebuild.**

## Claude Runner — autonomous Claude Code in ephemeral VMs

`automation/claude-runner/` contains two scripts:

| Script | Where it runs | What it does |
|--------|--------------|--------------|
| `launch.sh` | Your machine or Proxmox host | Clones a VM snapshot, pulls latest code, launches Claude |
| `run.sh` | Inside the dev VM | Runs `claude --dangerously-skip-permissions` in tmux, monitors and notifies |

`run.sh` is available on every VM at `/opt/devbox/automation/claude-runner/run.sh` — no copy needed.

### Setup

```bash
cp /opt/devbox/automation/claude-runner/config.env.example \
   /opt/devbox/automation/claude-runner/config.env
# Fill in: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
# Adjust:  SOURCE_LXC, SOURCE_SNAPSHOT, POST_CLONE_SCRIPT as needed
```

**Telegram bot:** message `@BotFather` → `/newbot` → copy token. Get chat ID from `https://api.telegram.org/bot<TOKEN>/getUpdates` after messaging the bot.

`config.env` is gitignored — never commit it.

### Run a task (full pipeline)

```bash
# From your machine:
bash /opt/devbox/automation/claude-runner/launch.sh \
  --prompt "Add email verification to the members module" \
  --branch feature/email-verification

# With a prompt file + context:
bash /opt/devbox/automation/claude-runner/launch.sh \
  --prompt-file /tmp/task.md \
  --context /opt/dev/workspace/members/README.md \
  --branch feature/my-feature
```

This will:
1. Clone LXC `SOURCE_LXC` from snapshot `SOURCE_SNAPSHOT`
2. Allocate a free ID (200–299) and IP (192.168.66.100–199)
3. Pull devbox + run `POST_CLONE_SCRIPT` (e.g. `apps/cluborbit.sh`) to update code
4. Start Claude autonomously in a tmux session
5. Send Telegram notifications for: started / done / failed / token limit / needs input

### Attach to interact

```bash
ssh root@<vm-ip>
tmux attach -t claude-runner
```

Claude is still running — type your response and it continues.

### Destroy VM when done

```bash
ssh root@192.168.88.21 "pct stop <id> && pct destroy <id>"
```

### Notifications

| Event | Trigger |
|-------|---------|
| 🚀 Started | VM cloned, Claude launched |
| ✅ Done | Claude exited 0 |
| ❌ Failed | Claude exited non-zero |
| ⚠️ Token limit | Output matches limit/usage keywords |
| ⏸ Needs input | No new output for `IDLE_TIMEOUT` seconds (default 120s) |

### Writing good prompts

Be explicit — vague prompts cause the ⏸ "needs input" pause:

```markdown
## Task
Add email verification to member registration.

## Repo
`members` at `/opt/dev/workspace/members/`

## What to do
1. Add `verified` boolean to Member model (default false)
2. Send verification email on registration via existing email service
3. Add POST /verify-email endpoint (accepts token, sets verified=true)
4. Block login for unverified members (return 403)

## Constraints
- Follow patterns in backend/src/routes/
- No new dependencies
- Add tests in backend/tests/
- Commit: feat(members): add email verification
```

## Claude Runner — PR automation

`/opt/devbox/automation/claude-runner/run.sh` runs Claude Code autonomously on a task inside a tmux session.

### Auto feature branches

When `--branch` is not provided and the workspace is on `dev` or `main`, the runner automatically creates a feature branch. The branch name is slugged from the first 6 words of the prompt:

```
"Fix confirmo healthcheck nginx route" → feature/fix-confirmo-healthcheck-nginx-route
```

Use `--branch` to override: `run.sh --branch feature/my-branch --prompt "..."`.

### PR creation on success

After a successful run (exit 0), if the workspace is on a `feature/*` branch and `gh` is authenticated, the runner automatically opens a PR against `dev` using the last commit message as the title.

Requires: `gh auth login` on the VM before running.

### Prod-guard CI

PRs to `main` in the cluborbit repo are gated by `.github/workflows/prod-guard.yml`, which blocks any PR touching:
- `deploy/dev/` — dev compose config
- `AGENT_CONTEXT.md` — agent session log
- `*.dev.{js,ts,jsx,tsx,json}` — dev-only source files
