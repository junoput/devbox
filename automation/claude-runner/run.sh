#!/usr/bin/env bash
# Run Claude Code autonomously on a task. Sends Telegram notifications on
# completion, failure, token limit, and when idle (waiting for input).
# Leaves tmux session open so you can attach and continue interactively.
#
# Usage:
#   run.sh --prompt "Add dark mode toggle to the shell"
#   run.sh --prompt-file /tmp/task.md --context members/README.md --branch feature/dark-mode
#
# Env vars (or source config.env):
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
#   WORKSPACE   (default /opt/dev/workspace)
#   IDLE_TIMEOUT  seconds of no output before "needs input" alert (default 120)

set -euo pipefail

WORKSPACE="${WORKSPACE:-/opt/dev/workspace}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-120}"
SESSION="claude-runner"
TS=$(date +%s)
TASK_FILE="/tmp/claude-task-${TS}.md"
WRAPPER="/tmp/claude-run-${TS}.sh"
LOG="/tmp/claude-log-${TS}.txt"
BRANCH=""
PROMPT_TEXT=""
CONTEXT_FILES=()

# ── Parse args ────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)       PROMPT_TEXT="$2";          shift 2 ;;
    --prompt-file)  PROMPT_TEXT="$(cat "$2")"; shift 2 ;;
    --context)      CONTEXT_FILES+=("$2");     shift 2 ;;
    --branch)       BRANCH="$2";               shift 2 ;;
    --workspace)    WORKSPACE="$2";            shift 2 ;;
    --session)      SESSION="$2";              shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$PROMPT_TEXT" ]] && { echo "ERROR: --prompt or --prompt-file required"; exit 1; }

# Auto-include context files if they exist
VM_CONTEXT="/opt/devbox/automation/claude-runner/vm-context.md"
APP_CONTEXT="$WORKSPACE/AGENT_CONTEXT.md"
[[ -f "$VM_CONTEXT"  && ! " ${CONTEXT_FILES[*]} " =~ "$VM_CONTEXT"  ]] && CONTEXT_FILES=("$VM_CONTEXT"  "${CONTEXT_FILES[@]}")
[[ -f "$APP_CONTEXT" && ! " ${CONTEXT_FILES[*]} " =~ "$APP_CONTEXT" ]] && CONTEXT_FILES=("$APP_CONTEXT" "${CONTEXT_FILES[@]}")

# ── Telegram ──────────────────────────────────────────────────

notify() {
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
  curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "text=$1" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    -o /dev/null
}

# ── Branch setup ──────────────────────────────────────────────

if [[ -n "$BRANCH" ]]; then
  cd "$WORKSPACE"
  git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
  echo "▶ Branch: $BRANCH"
fi

# ── Build task file ───────────────────────────────────────────

{
  echo "$PROMPT_TEXT"
  for f in "${CONTEXT_FILES[@]}"; do
    echo ""
    echo "---"
    echo "# Context: $(basename "$f")"
    echo ""
    cat "$f"
  done
  echo ""
  echo "---"
  echo "# Required: update agent context"
  echo ""
  echo "When the task is complete, update \`$APP_CONTEXT\` — append a row to the Session log"
  echo "table and update any sections that changed (Known issues, Stack overview, etc.)."
  echo "Format: | $(date +%Y-%m-%d) | Claude | \${BRANCH:-current branch} | <one-line summary> |"
} > "$TASK_FILE"

echo "▶ Task written to $TASK_FILE"

# ── Wrapper script (avoids quoting issues in tmux) ────────────

cat > "$WRAPPER" << WRAPPER_EOF
#!/usr/bin/env bash
set -o pipefail
cd "$WORKSPACE"
PROMPT=\$(cat "$TASK_FILE")
claude --dangerously-skip-permissions "\$PROMPT" 2>&1 | tee "$LOG"
echo "EXIT_CODE:\${PIPESTATUS[0]}" >> "$LOG"
WRAPPER_EOF
chmod +x "$WRAPPER"

# ── Launch tmux session ───────────────────────────────────────

# Clean stale default socket (left behind when tmux server crashes)
TMUX_SOCK="/tmp/tmux-$(id -u)/default"
if [ -S "$TMUX_SOCK" ] && ! tmux list-sessions &>/dev/null; then
  rm -f "$TMUX_SOCK"
fi

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" "bash $WRAPPER"

VM_IP=$(hostname -I | awk '{print $1}')
notify "🤖 *Claude runner started*
Branch: \`${BRANCH:-current}\`
Session: \`$SESSION\`
Log: \`$LOG\`

Attach: \`ssh root@${VM_IP}\` then \`tmux attach -t $SESSION\`"

echo "▶ Claude running in tmux session '$SESSION'"
echo "  Attach: tmux attach -t $SESSION"
echo "  Log:    tail -f $LOG"

# ── Monitor loop ──────────────────────────────────────────────

LAST_SIZE=0
IDLE_SINCE=$(date +%s)
NOTIFIED_IDLE=false

while tmux has-session -t "$SESSION" 2>/dev/null; do
  sleep 10

  # Exit detected
  if grep -q "^EXIT_CODE:" "$LOG" 2>/dev/null; then
    EXIT_CODE=$(grep "^EXIT_CODE:" "$LOG" | tail -1 | cut -d: -f2 | tr -d '[:space:]')
    LAST_LINES=$(grep -v "^EXIT_CODE:" "$LOG" | tail -8 | tr '\n' ' ')
    if [[ "$EXIT_CODE" == "0" ]]; then
      notify "✅ *Claude finished successfully*
Branch: \`${BRANCH:-current}\`

_Last output:_
\`\`\`
$(grep -v "^EXIT_CODE:" "$LOG" | tail -5)
\`\`\`
Attach to review: \`tmux attach -t $SESSION\`"
    else
      notify "❌ *Claude failed* (exit \`$EXIT_CODE\`)
Branch: \`${BRANCH:-current}\`

_Last output:_
\`\`\`
$(grep -v "^EXIT_CODE:" "$LOG" | tail -5)
\`\`\`
Attach: \`tmux attach -t $SESSION\`"
    fi
    echo "▶ Done (exit $EXIT_CODE)"
    break
  fi

  # Token / rate limit
  if tail -10 "$LOG" 2>/dev/null | grep -qiE "usage limit|context window|token limit|rate limit|max.*token"; then
    notify "⚠️ *Token or rate limit hit*
Branch: \`${BRANCH:-current}\`

_Last output:_
\`\`\`
$(tail -5 "$LOG")
\`\`\`
Attach: \`tmux attach -t $SESSION\`"
    echo "▶ Token/rate limit detected"
    break
  fi

  # Idle detection (waiting for input)
  CURRENT_SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [[ "$CURRENT_SIZE" -ne "$LAST_SIZE" ]]; then
    LAST_SIZE=$CURRENT_SIZE
    IDLE_SINCE=$(date +%s)
    NOTIFIED_IDLE=false
  else
    IDLE_SECS=$(( $(date +%s) - IDLE_SINCE ))
    if [[ $IDLE_SECS -gt $IDLE_TIMEOUT && "$NOTIFIED_IDLE" == "false" ]]; then
      NOTIFIED_IDLE=true
      LAST_OUTPUT=$(tail -5 "$LOG" 2>/dev/null | tr '\n' ' ')
      notify "⏸ *Claude is waiting for input* (idle ${IDLE_SECS}s)
The task may be too vague or Claude needs a decision.

_Last output:_
\`\`\`
$(tail -5 "$LOG")
\`\`\`
Attach to respond: \`tmux attach -t $SESSION\`"
      echo "▶ Idle ${IDLE_SECS}s — notified"
    fi
  fi
done
