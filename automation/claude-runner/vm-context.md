# Dev VM Context

You are running inside a Debian 12 LXC dev VM provisioned by devbox.

## Environment

- Shell: zsh (oh-my-zsh)
- Terminal multiplexer: tmux (you are likely already inside a tmux session)
- Editor: neovim (`nvim`)
- Runtime: Node LTS, Python 3, Rust (if provisioned)
- Containers: Podman + podman-compose (rootful, no daemon)
- Auth: GitHub CLI (`gh`), Claude Code (`claude`)

## Key paths

| Path | Contents |
|------|----------|
| `/opt/devbox/` | devbox repo — VM provisioning scripts |
| `/opt/devbox/setup.sh` | base bootstrap (idempotent) |
| `/opt/devbox/provision.sh` | module installer menu |
| `/opt/devbox/apps/` | app-specific provisioners |
| `$WORKSPACE/` | app source code (set by runner) |
| `$WORKSPACE/AGENT_CONTEXT.md` | app-specific context — read this first |

## Git flow

All changes must be committed and pushed upstream — local changes are lost when the VM is destroyed.

```bash
# Stage and commit
git add <files>
git commit -m "type(scope): description"

# Push (GitHub App token is pre-configured for read; use gh auth for write)
git push origin <branch>
```

If push requires auth, check `gh auth status`. The GitHub App token used for cloning is read-only.

## Adding tools to devbox

If you install a tool manually and it should be available on all VMs:

1. Add it to the appropriate script in `/opt/devbox/`:
   - Base tool → `setup.sh`
   - Optional module → `modules/<tool>.sh`
   - App dependency → `apps/<app>.sh`
2. Commit and push to the devbox repo (`junoput/devbox` on `main`)

**Do not leave tool installations only in this VM** — they will be lost on next clone.

## Updating AGENT_CONTEXT.md

At the end of every session, update `$WORKSPACE/AGENT_CONTEXT.md` with:
- What you changed and why
- Current state of the app / stack
- Any issues encountered or left unresolved
- What the next agent should know before starting

This file is the handoff note between agents. Keep it accurate and concise.
