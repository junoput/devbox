# desc: ClubOrbit dev environment (pull all repos, configure Podman stack)
set -euo pipefail

DEV_DIR=/opt/dev

pull_repo() {
  local dir="$1" repo="$2"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --quiet --all
    if git -C "$dir" show-ref --quiet refs/remotes/origin/dev; then
      git -C "$dir" checkout dev --quiet 2>/dev/null || git -C "$dir" checkout -b dev origin/dev --quiet
      git -C "$dir" reset --hard origin/dev --quiet
    else
      git -C "$dir" reset --hard origin/main --quiet
    fi
  else
    mkdir -p "$(dirname "$dir")"
    git clone --quiet "git@github.com:${repo}" "$dir"
  fi
}

echo "▶ Pulling ClubOrbit repos"
WORKSPACE="$DEV_DIR/workspace"
pull_repo "$WORKSPACE/cluborbit"            "ClubOrbit/cluborbit"
pull_repo "$WORKSPACE/event-planner"        "ClubOrbit/event-planner"
pull_repo "$WORKSPACE/confirmo"             "ClubOrbit/confirmo"
pull_repo "$WORKSPACE/bulk-buzz"            "ClubOrbit/bulk-buzz"
pull_repo "$WORKSPACE/members"              "ClubOrbit/members"
pull_repo "$WORKSPACE/orbit-dashboard"      "ClubOrbit/orbit-dashboard"
pull_repo "$WORKSPACE/orbit-telemetry"      "ClubOrbit/orbit-telemetry"
pull_repo "$WORKSPACE/orbit-backup"         "ClubOrbit/orbit-backup"

echo "▶ Running dev setup"
bash "$WORKSPACE/cluborbit/deploy/dev/setup.sh" --no-pull

echo "▶ Configuring Keycloak realm"
bash "$WORKSPACE/cluborbit/keycloak/setup-dev-realm.sh"

CONTEXT_FILE="$WORKSPACE/AGENT_CONTEXT.md"
if [ ! -f "$CONTEXT_FILE" ]; then
  echo "▶ Creating initial AGENT_CONTEXT.md"
  SHELL_COMMIT=$(git -C "$WORKSPACE/cluborbit" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  cat > "$CONTEXT_FILE" << EOF
# ClubOrbit Dev — Agent Context

This file is maintained by Claude agents. Update it at the end of every session.

## Stack overview

Multi-repo monorepo. All repos cloned to \`/opt/dev/workspace/\` on branch \`dev\`.
Dev stack runs via Podman + podman-compose (rootful). Vite HMR hot reload active.

## Repos

| Repo | Path | Purpose |
|------|------|---------|
| cluborbit | workspace/cluborbit | Main shell app + deploy configs |
| members | workspace/members | Members module (frontend + FastAPI backend) |
| event-planner | workspace/event-planner | Event planner module |
| bulk-buzz | workspace/bulk-buzz | Bulk messaging module |
| confirmo | workspace/confirmo | Confirmation/forms module |
| orbit-dashboard | workspace/orbit-dashboard | Admin dashboard |
| orbit-telemetry | workspace/orbit-telemetry | Telemetry service |
| orbit-backup | workspace/orbit-backup | Backup service |

## Key containers

| Container | Role | Port |
|-----------|------|------|
| proxy | nginx reverse proxy | 80 / 443 |
| dev-shell | main Vite dev server (HMR) | — |
| dev-gateway | API gateway / auth middleware | 3001 |
| dev-keycloak | Keycloak auth (slow start ~2min) | — |
| dev-members-api | Members FastAPI backend | 8001 |
| dev-members-dev | Members Vite dev server (HMR) | 5175 |
| dev-event-planner-* | Event planner frontend + API + DB | — |
| dev-bulk-buzz-* | Bulk buzz frontend + API | — |
| dev-confirmo* | Confirmo frontend + backend | — |
| dev-person-server | Person DB service | 8000 |
| orbit-telemetry | Telemetry | 4100 |
| orbit-dashboard | Dashboard | — |
| orbit-backup | Backup | 4200 |

## Access

- App: https://\$(hostname -I | awk '{print \$1}') (self-signed cert)
- Login: admin@orbit.local / Admin1234!
- Keycloak: /auth/

## Stack management

\`\`\`bash
# Start / update all repos + stack
bash /opt/devbox/apps/cluborbit.sh

# Restart a container
podman restart <name>

# View logs
podman logs <name> 2>&1 | tail -50

# Rebuild a service (e.g. after Dockerfile change)
cd /opt/dev/workspace/cluborbit/deploy/dev
podman-compose build <service> && podman-compose up -d <service>
\`\`\`

## Known issues / gotchas

- Keycloak takes ~2 min to start — dev-gateway stays unhealthy until it's up
- All repos are private (ClubOrbit org) — push via SSH (VM key registered on GitHub)
- Hot reload: edit files in workspace/ directly; browser updates automatically
- Podman network \`cluborbit_shared\` must use subnet 10.94.0.0/24 (gateway 10.94.0.1) for nginx resolver

## Session log

| Date | Agent | Branch | Summary |
|------|-------|--------|---------|
| $(date +%Y-%m-%d) | cluborbit.sh | — | Initial setup (shell@${SHELL_COMMIT}) |
EOF
  echo "✓ AGENT_CONTEXT.md created at $CONTEXT_FILE"
fi

echo "✓ ClubOrbit dev environment ready"
echo "  App: http://$(hostname -I | awk '{print $1}')"
echo "  Orbit: http://$(hostname -I | awk '{print $1}'):4101"
echo "  Context: $CONTEXT_FILE"
