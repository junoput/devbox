# desc: ClubOrbit dev environment (pull all repos, configure Podman stack)
set -euo pipefail

SECRETS=/root/.secrets/github-app.env
DEV_DIR=/opt/dev

if [ ! -f "$SECRETS" ]; then
  echo "ERROR: $SECRETS missing. Copy GitHub App credentials first:"
  echo "  mkdir -p /root/.secrets && chmod 700 /root/.secrets"
  echo "  cat > $SECRETS   # paste GITHUB_APP_ID, GITHUB_INSTALL_ID, GITHUB_APP_PEM"
  exit 1
fi

if [ ! -f /usr/local/bin/github-app-token ]; then
  echo "▶ Installing github-app-token helper"
  pip3 install --quiet jwt cryptography requests
  cat > /usr/local/bin/github-app-token << 'PYEOF'
#!/usr/bin/env python3
import os, time, json, jwt, requests
app_id  = os.environ["GITHUB_APP_ID"]
inst_id = os.environ["GITHUB_INSTALL_ID"]
pem     = open(os.environ["GITHUB_APP_PEM"]).read()
now     = int(time.time())
payload = {"iat": now - 60, "exp": now + 540, "iss": app_id}
token   = jwt.encode(payload, pem, algorithm="RS256")
r = requests.post(
  f"https://api.github.com/app/installations/{inst_id}/access_tokens",
  headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
)
print(r.json()["token"])
PYEOF
  chmod +x /usr/local/bin/github-app-token
fi

set -a; source "$SECRETS"; set +a
TOKEN=$(GITHUB_APP_ID="$GITHUB_APP_ID" GITHUB_INSTALL_ID="$GITHUB_INSTALL_ID" \
  GITHUB_APP_PEM="$GITHUB_APP_PEM" /usr/local/bin/github-app-token)

pull_repo() {
  local dir="$1" repo="$2"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" remote set-url origin "https://x-access-token:${TOKEN}@github.com/${repo}"
    git -C "$dir" fetch --quiet origin main
    git -C "$dir" reset --hard origin/main
    git -C "$dir" remote set-url origin "https://github.com/${repo}"
  else
    mkdir -p "$(dirname "$dir")"
    git clone --quiet "https://x-access-token:${TOKEN}@github.com/${repo}" "$dir"
    git -C "$dir" remote set-url origin "https://github.com/${repo}"
  fi
}

echo "▶ Pulling ClubOrbit repos"
WORKSPACE="$DEV_DIR/workspace"
pull_repo "$DEV_DIR"                        "ClubOrbit/cluborbit"
pull_repo "$WORKSPACE/event-planner"        "ClubOrbit/event-planner"
pull_repo "$WORKSPACE/confirmo"             "ClubOrbit/confirmo"
pull_repo "$WORKSPACE/bulk-buzz"            "ClubOrbit/bulk-buzz"
pull_repo "$WORKSPACE/members"              "ClubOrbit/members"
pull_repo "$WORKSPACE/orbit-dashboard"      "ClubOrbit/orbit-dashboard"
pull_repo "$WORKSPACE/orbit-telemetry"      "ClubOrbit/orbit-telemetry"
pull_repo "$WORKSPACE/orbit-backup"         "ClubOrbit/orbit-backup"

echo "▶ Running dev-setup.sh"
bash /root/dev-setup.sh

echo "✓ ClubOrbit dev environment ready"
echo "  App: http://$(hostname -I | awk '{print $1}')"
echo "  Orbit: http://$(hostname -I | awk '{print $1}'):4101"
