#!/usr/bin/env bash
# Clone a dev VM snapshot, run a post-clone provisioner, and launch Claude autonomously.
# Runs from your local machine or the Proxmox host.
#
# Usage:
#   launch.sh --prompt "Add dark mode to shell"
#   launch.sh --prompt-file /tmp/task.md --branch feature/my-feature [--context file...]
#   launch.sh --prompt "Quick fix" --model haiku --effort low --no-review
#   launch.sh --prompt "Security audit" --model opus --effort high --max-turns 80
#
# Requires: config.env alongside this script (copy from config.env.example)
#
# run.sh is read from /opt/devbox/automation/claude-runner/run.sh on the VM —
# devbox is already cloned there by setup.sh, and this script pulls it before use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER_PATH="/opt/devbox/automation/claude-runner/run.sh"

# Load config
[[ -f "$SCRIPT_DIR/config.env" ]] || {
  echo "ERROR: $SCRIPT_DIR/config.env missing (copy from config.env.example)"
  exit 1
}
source "$SCRIPT_DIR/config.env"

BRANCH=""
PROMPT_TEXT=""
CONTEXT_FILES=()
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-}"
MAX_TURNS="${MAX_TURNS:-}"
NO_PREFLIGHT="${NO_PREFLIGHT:-false}"
NO_REVIEW="${NO_REVIEW:-false}"

# ── Parse args ────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)        PROMPT_TEXT="$2";          shift 2 ;;
    --prompt-file)   PROMPT_TEXT="$(cat "$2")"; shift 2 ;;
    --context)       CONTEXT_FILES+=("$2");     shift 2 ;;
    --branch)        BRANCH="$2";               shift 2 ;;
    --model)         CLAUDE_MODEL="$2";         shift 2 ;;
    --effort)        CLAUDE_EFFORT="$2";        shift 2 ;;
    --max-turns)     MAX_TURNS="$2";            shift 2 ;;
    --no-preflight)  NO_PREFLIGHT=true;         shift ;;
    --no-review)     NO_REVIEW=true;            shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$PROMPT_TEXT" ]] && { echo "ERROR: --prompt or --prompt-file required"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────

notify() {
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
  curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "text=$1" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    -o /dev/null
}

px() { ssh -i "$PROXMOX_SSH_KEY" -o StrictHostKeyChecking=no "root@$PROXMOX_HOST" "$@"; }
vm() { ssh -i "$LXC_SSH_KEY"     -o StrictHostKeyChecking=no "root@$NEW_IP"       "$@"; }

# ── Allocate free LXC ID ──────────────────────────────────────

echo "▶ Allocating LXC ID..."
USED_IDS=$(px "pct list" | awk 'NR>1 {print $1}')
NEW_ID=""
for id in $(seq "$LXC_ID_RANGE_START" "$LXC_ID_RANGE_END"); do
  if ! echo "$USED_IDS" | grep -q "^${id}$"; then
    NEW_ID=$id; break
  fi
done
[[ -z "$NEW_ID" ]] && { echo "ERROR: No free LXC ID in range $LXC_ID_RANGE_START-$LXC_ID_RANGE_END"; exit 1; }

# ── Allocate free IP ──────────────────────────────────────────

echo "▶ Allocating IP..."
USED_IPS=$(px "pct list" | awk 'NR>1 {print $1}' \
  | xargs -I{} sh -c "ssh -i $PROXMOX_SSH_KEY -o StrictHostKeyChecking=no root@$PROXMOX_HOST 'pct config {}' 2>/dev/null || true" \
  | grep "^net0" | grep -oE "${LXC_IP_PREFIX}\.[0-9]+" | grep -oE "[0-9]+$" || true)
NEW_IP_LAST=""
for ip in $(seq "$LXC_IP_RANGE_START" "$LXC_IP_RANGE_END"); do
  if ! echo "$USED_IPS" | grep -q "^${ip}$"; then
    NEW_IP_LAST=$ip; break
  fi
done
[[ -z "$NEW_IP_LAST" ]] && { echo "ERROR: No free IP in $LXC_IP_PREFIX.$LXC_IP_RANGE_START-$LXC_IP_RANGE_END"; exit 1; }
NEW_IP="${LXC_IP_PREFIX}.${NEW_IP_LAST}"

HOSTNAME="${HOSTNAME_PREFIX:-claude-dev}-${NEW_ID}"
echo "▶ LXC $NEW_ID — IP $NEW_IP — hostname $HOSTNAME"

# ── Clone VM ──────────────────────────────────────────────────

notify "🔄 *Cloning dev VM*
ID: \`$NEW_ID\` — IP: \`$NEW_IP\`
Source: LXC $SOURCE_LXC @ \`$SOURCE_SNAPSHOT\`
Branch: \`${BRANCH:-current}\`"

echo "▶ Cloning LXC $SOURCE_LXC → $NEW_ID..."
px "pct clone $SOURCE_LXC $NEW_ID \
  --snapname $SOURCE_SNAPSHOT \
  --hostname $HOSTNAME \
  --full"
px "pct set $NEW_ID --net0 name=eth0,bridge=$LXC_BRIDGE,ip=${NEW_IP}/24,gw=$LXC_GATEWAY"
px "pct start $NEW_ID"

# ── Wait for SSH ──────────────────────────────────────────────

echo "▶ Waiting for SSH on $NEW_IP..."
for i in $(seq 1 30); do
  if ssh -i "$LXC_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
       "root@$NEW_IP" "true" 2>/dev/null; then
    echo "✓ SSH ready"; break
  fi
  [[ $i -eq 30 ]] && { echo "ERROR: SSH timeout"; exit 1; }
  sleep 3
done

# ── Update devbox (ensures run.sh is latest) ──────────────────

echo "▶ Updating devbox on VM..."
vm "git -C /opt/devbox pull --quiet"

# ── Copy secrets ──────────────────────────────────────────────

if [[ -n "${SECRETS_SOURCE_DIR:-}" ]]; then
  echo "▶ Copying secrets from $SECRETS_SOURCE_DIR..."
  px "pct exec $SOURCE_LXC -- find $SECRETS_SOURCE_DIR -type f" | while read -r f; do
    px "pct exec $SOURCE_LXC -- cat $f" | \
      vm "mkdir -p \$(dirname $f) && chmod 700 \$(dirname $f) && cat > $f && chmod 600 $f"
  done
  echo "✓ Secrets copied"
fi

# ── Post-clone provisioner ────────────────────────────────────

if [[ -n "${POST_CLONE_SCRIPT:-}" ]]; then
  echo "▶ Running: $POST_CLONE_SCRIPT"
  vm "bash $POST_CLONE_SCRIPT"
  echo "✓ Provisioner done"
fi

# ── Write runner config on VM ─────────────────────────────────

vm "cat > /root/runner.env" << EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
WORKSPACE=${WORKSPACE}
IDLE_TIMEOUT=${IDLE_TIMEOUT:-120}
CLAUDE_MODEL=${CLAUDE_MODEL:-}
CLAUDE_EFFORT=${CLAUDE_EFFORT:-}
MAX_TURNS=${MAX_TURNS:-50}
NO_PREFLIGHT=${NO_PREFLIGHT}
NO_REVIEW=${NO_REVIEW}
EOF

# ── Build and transfer prompt ─────────────────────────────────

PROMPT_FILE="/tmp/claude-launch-task-$$.md"
{
  echo "$PROMPT_TEXT"
  for f in "${CONTEXT_FILES[@]}"; do
    echo ""
    echo "---"
    echo "# Context: $(basename "$f")"
    echo ""
    cat "$f"
  done
} > "$PROMPT_FILE"

scp -i "$LXC_SSH_KEY" -o StrictHostKeyChecking=no "$PROMPT_FILE" "root@$NEW_IP:/root/task.md"
rm "$PROMPT_FILE"

# ── Launch runner ─────────────────────────────────────────────

echo "▶ Launching Claude runner on $NEW_IP..."
BRANCH_ARG=""
[[ -n "$BRANCH" ]] && BRANCH_ARG="--branch $BRANCH"

EXTRA_ARGS=""
[[ -n "$CLAUDE_MODEL"  ]] && EXTRA_ARGS+=" --model $CLAUDE_MODEL"
[[ -n "$CLAUDE_EFFORT" ]] && EXTRA_ARGS+=" --effort $CLAUDE_EFFORT"
[[ -n "$MAX_TURNS"     ]] && EXTRA_ARGS+=" --max-turns $MAX_TURNS"
[[ "$NO_PREFLIGHT" == "true" ]] && EXTRA_ARGS+=" --no-preflight"
[[ "$NO_REVIEW"    == "true" ]] && EXTRA_ARGS+=" --no-review"

vm "nohup bash -c 'source /root/runner.env && bash $RUNNER_PATH --prompt-file /root/task.md $BRANCH_ARG $EXTRA_ARGS > /root/launch.log 2>&1' &"

notify "🚀 *Claude dev VM launched*
ID: \`$NEW_ID\` — IP: \`$NEW_IP\`
Branch: \`${BRANCH:-current}\`
Model: \`${CLAUDE_MODEL:-auto}\`  Effort: \`${CLAUDE_EFFORT:-auto}\`

SSH in: \`ssh root@${NEW_IP}\`
Attach Claude: \`tmux attach -t claude-runner\`
Live log: \`tail -f /tmp/claude-log-*.txt\`

Destroy when done:
\`ssh root@$PROXMOX_HOST 'pct stop $NEW_ID && pct destroy $NEW_ID'\`"

echo ""
echo "✓ Claude running on $NEW_IP (LXC $NEW_ID)"
echo "  SSH:     ssh -i $LXC_SSH_KEY root@$NEW_IP"
echo "  Attach:  tmux attach -t claude-runner"
echo "  Log:     tail -f /tmp/claude-log-*.txt"
echo "  Destroy: ssh root@$PROXMOX_HOST 'pct stop $NEW_ID && pct destroy $NEW_ID'"
