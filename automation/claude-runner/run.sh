#!/usr/bin/env bash
# Run Claude Code autonomously on a task. Sends Telegram notifications on
# completion, failure, token limit, and when idle (waiting for input).
# Leaves tmux session open for interactive follow-up.
#
# Usage:
#   run.sh --prompt "Add dark mode toggle to the shell"
#   run.sh --prompt-file /tmp/task.md --model opus --effort high --max-turns 40
#   run.sh --prompt "Quick typo fix" --model haiku --no-review
#
# Env vars (or source runner.env):
#   TELEGRAM_BOT_TOKEN      TELEGRAM_CHAT_ID
#   WORKSPACE               default: /opt/dev/workspace
#   IDLE_TIMEOUT            seconds of no output before idle alert (default 120)
#   CLAUDE_MODEL            haiku|sonnet|opus (default: auto via preflight)
#   CLAUDE_EFFORT           low|medium|high|xhigh (default: auto via preflight)
#   MAX_TURNS               max conversation turns (default 50)
#   NO_PREFLIGHT            true to skip Haiku complexity analysis
#   NO_REVIEW               true to skip Haiku diff review before PR
#   ANTHROPIC_API_KEY       injected into session (sourced from ANTHROPIC_SECRETS_FILE if unset)
#   ANTHROPIC_SECRETS_FILE  path to file exporting ANTHROPIC_API_KEY (default /root/.secrets/anthropic.env)

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
MODEL="${CLAUDE_MODEL:-}"
EFFORT="${CLAUDE_EFFORT:-}"
MAX_TURNS="${MAX_TURNS:-50}"
NO_PREFLIGHT="${NO_PREFLIGHT:-false}"
NO_REVIEW="${NO_REVIEW:-false}"

# ── Parse args ────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)        PROMPT_TEXT="$2";          shift 2 ;;
    --prompt-file)   PROMPT_TEXT="$(cat "$2")"; shift 2 ;;
    --context)       CONTEXT_FILES+=("$2");     shift 2 ;;
    --branch)        BRANCH="$2";               shift 2 ;;
    --workspace)     WORKSPACE="$2";            shift 2 ;;
    --session)       SESSION="$2";              shift 2 ;;
    --model)         MODEL="$2";                shift 2 ;;
    --effort)        EFFORT="$2";               shift 2 ;;
    --max-turns)     MAX_TURNS="$2";            shift 2 ;;
    --no-preflight)  NO_PREFLIGHT=true;         shift ;;
    --no-review)     NO_REVIEW=true;            shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$PROMPT_TEXT" ]] && { echo "ERROR: --prompt or --prompt-file required"; exit 1; }

# ── Auto-include context files ────────────────────────────────

VM_CONTEXT="/opt/devbox/automation/claude-runner/vm-context.md"
APP_CONTEXT="$WORKSPACE/AGENT_CONTEXT.md"
[[ -f "$VM_CONTEXT"  && ! " ${CONTEXT_FILES[*]} " =~ "$VM_CONTEXT"  ]] && CONTEXT_FILES=("$VM_CONTEXT"  "${CONTEXT_FILES[@]}")
[[ -f "$APP_CONTEXT" && ! " ${CONTEXT_FILES[*]} " =~ "$APP_CONTEXT" ]] && CONTEXT_FILES=("$APP_CONTEXT" "${CONTEXT_FILES[@]}")

# ── Load API key from secrets ─────────────────────────────────

ANTHROPIC_SECRETS_FILE="${ANTHROPIC_SECRETS_FILE:-/root/.secrets/anthropic.env}"
if [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$ANTHROPIC_SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ANTHROPIC_SECRETS_FILE" 2>/dev/null || true
fi

# ── Helpers ───────────────────────────────────────────────────

notify() {
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
  curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "text=$1" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    -o /dev/null
}

# Haiku call: single non-interactive prompt, cheap + fast
haiku_call() {
  local prompt="$1"
  local api_key_env=""
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && api_key_env="ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"

  if [ "$(id -u)" -eq 0 ] && id claude &>/dev/null; then
    env $api_key_env su -s /bin/bash claude -c \
      "claude --model claude-haiku-4-5 -p \"\$1\"" _ "$prompt" 2>/dev/null
  else
    env $api_key_env claude --model claude-haiku-4-5 -p "$prompt" 2>/dev/null
  fi
}

# Map short names to full model IDs
resolve_model() {
  case "${1:-}" in
    haiku)  echo "claude-haiku-4-5"   ;;
    sonnet) echo "claude-sonnet-4-6"  ;;
    opus)   echo "claude-opus-4-7"    ;;
    "")     echo ""                   ;;
    *)      echo "$1"                 ;;
  esac
}

# Parse JSON stream log for session status (Python3 always available on VM)
parse_log() {
  python3 - "$1" << 'PYEOF'
import json, sys

AUTH_KEYS  = ['invalid api key','authentication failed','please run claude login',
              'not logged in','not authenticated','unauthorized','api key is invalid']
TOKEN_KEYS = ['max_tokens','token_limit','context_length','context window']

log_path = sys.argv[1]
result_event = None
auth_error   = False
token_limit  = False

try:
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            lower = line.lower()
            if any(k in lower for k in AUTH_KEYS):
                auth_error = True
            try:
                event = json.loads(line)
                etype = event.get('type','')
                if etype == 'result':
                    result_event = event
                    sr = str(event.get('stop_reason','') or event.get('subtype','')).lower()
                    if any(k in sr for k in TOKEN_KEYS):
                        token_limit = True
                elif etype in ('system','assistant'):
                    msg = str(event.get('message','') or event.get('content','')).lower()
                    if any(k in msg for k in AUTH_KEYS):
                        auth_error = True
            except (json.JSONDecodeError, ValueError):
                pass
except FileNotFoundError:
    pass

out = {'done': result_event is not None, 'auth_error': auth_error, 'token_limit': token_limit}
if result_event:
    sr = result_event.get('stop_reason') or result_event.get('subtype') or 'unknown'
    out.update({
        'stop_reason' : sr,
        'is_error'    : result_event.get('is_error', False),
        'num_turns'   : result_event.get('num_turns', 0),
        'cost_usd'    : round(result_event.get('cost_usd', 0), 4),
        'usage'       : result_event.get('usage', {}),
    })

print(json.dumps(out))
PYEOF
}

get_field() {
  # get_field <json> <key> <default>
  echo "$1" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read()); v=d.get('$2')
    print(str(v) if v is not None else '$3')
except: print('$3')
" 2>/dev/null || echo "$3"
}

# ── Preflight: auto-select model + effort via Haiku ───────────

preflight() {
  [[ "$NO_PREFLIGHT" == "true" ]] && return 0
  [[ -n "$MODEL" && -n "$EFFORT" ]] && { echo "▶ Model: $MODEL  Effort: $EFFORT  MaxTurns: $MAX_TURNS"; return 0; }

  echo "▶ Preflight: analysing task complexity..."

  local analysis
  analysis=$(haiku_call "Analyse this autonomous coding task. Return ONLY valid JSON, no other text.

Format: {\"model\":\"haiku|sonnet|opus\",\"effort\":\"low|medium|high\",\"max_turns\":<10-80>,\"notes\":\"<reason ≤12 words>\"}

Guidelines:
- haiku:  typo fix, single-file config/docs, trivial rename
- sonnet: new feature, multi-file refactor, test suite (default)
- opus:   security audit, complex architecture, cross-repo changes

Task (first 2000 chars):
${PROMPT_TEXT:0:2000}" || echo "")

  if [[ -n "$analysis" ]]; then
    local parsed
    parsed=$(echo "$analysis" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read().strip())
    print(d.get('model',''), d.get('effort',''), d.get('max_turns',''), d.get('notes',''))
except: print('','','','')
" 2>/dev/null || echo "")

    local pmodel peffort pturns pnotes
    read -r pmodel peffort pturns pnotes <<< "$parsed"

    [[ -z "$MODEL"     && -n "$pmodel"  ]] && MODEL="$pmodel"
    [[ -z "$EFFORT"    && -n "$peffort" ]] && EFFORT="$peffort"
    [[ -z "$MAX_TURNS" && "$pturns" =~ ^[0-9]+$ && $pturns -gt 0 ]] && MAX_TURNS="$pturns"

    echo "  → Model: ${MODEL:-default}  Effort: ${EFFORT:-default}  MaxTurns: $MAX_TURNS"
    [[ -n "$pnotes" ]] && echo "  → $pnotes"
  else
    echo "  → Preflight unavailable (haiku call failed — using defaults)"
  fi
}

# ── Diff review: Haiku checks changes before PR ───────────────

REVIEW_SAFE="true"
REVIEW_SUMMARY=""
REVIEW_ISSUES=""

diff_review() {
  [[ "$NO_REVIEW" == "true" ]] && return 0

  local diff_output
  diff_output=$(git -C "$WORKSPACE" diff HEAD~1 2>/dev/null || \
                git -C "$WORKSPACE" diff --cached 2>/dev/null || \
                git -C "$WORKSPACE" diff 2>/dev/null || echo "")

  [[ "${#diff_output}" -lt 50 ]] && return 0

  echo "▶ Diff review (Haiku)..."

  local review
  review=$(haiku_call "Review this git diff before merging to dev. Return ONLY valid JSON.

Format: {\"safe_to_merge\":true|false,\"summary\":\"<one line>\",\"issues\":[{\"severity\":\"low|medium|high\",\"description\":\"...\"}]}

Focus: obvious bugs, broken logic, missing error handling, security. Ignore style/whitespace.

Diff (truncated to 8000 chars):
${diff_output:0:8000}" || echo "")

  if [[ -n "$review" ]]; then
    REVIEW_SAFE=$(get_field    "$review" "safe_to_merge" "true")
    REVIEW_SUMMARY=$(get_field "$review" "summary"       "")
    REVIEW_ISSUES=$(echo "$review" | python3 -c "
import json,sys
try:
    for i in json.loads(sys.stdin.read()).get('issues',[]):
        print(f\"  [{i.get('severity','?').upper()}] {i.get('description','')}\")
except: pass
" 2>/dev/null || echo "")

    echo "  → ${REVIEW_SUMMARY:-no summary}"
    [[ -n "$REVIEW_ISSUES" ]] && echo "$REVIEW_ISSUES"
    [[ "$REVIEW_SAFE" =~ ^[Ff]alse$ ]] && echo "  ⚠  Haiku flagged this as NOT safe to merge"
  else
    echo "  → Review unavailable"
  fi
}

# ── Preflight ─────────────────────────────────────────────────

preflight
MODEL_ID=$(resolve_model "$MODEL")

# ── Branch setup ──────────────────────────────────────────────

if [[ -z "$BRANCH" ]]; then
  CURRENT_BRANCH=$(git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ "$CURRENT_BRANCH" == "dev" || "$CURRENT_BRANCH" == "main" ]]; then
    SLUG=$(echo "$PROMPT_TEXT" | sed 's/^feature\///i' | tr '[:upper:]' '[:lower:]' \
      | tr -cs 'a-z0-9 ' ' ' | tr ' ' '-' | cut -d- -f1-6 | sed 's/-*$//')
    SLUG="${SLUG:0:50}"
    [[ -n "$SLUG" ]] && BRANCH="feature/$SLUG"
  fi
fi

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
  echo "When complete, update \`$APP_CONTEXT\` — append a row to the Session log table"
  echo "and update any sections that changed (Known issues, Stack overview, etc.)."
  echo "Format: | $(date +%Y-%m-%d) | Claude | \${BRANCH:-current branch} | <one-line summary> |"
} > "$TASK_FILE"

echo "▶ Task written to $TASK_FILE"

# ── Build wrapper ─────────────────────────────────────────────

CLAUDE_FLAGS="--output-format stream-json --dangerously-skip-permissions"
[[ -n "$MODEL_ID"  ]] && CLAUDE_FLAGS+=" --model $MODEL_ID"
[[ -n "$EFFORT"    ]] && CLAUDE_FLAGS+=" --effort $EFFORT"
[[ -n "$MAX_TURNS" ]] && CLAUDE_FLAGS+=" --max-turns $MAX_TURNS"

cat > "$WRAPPER" << WRAPPER_EOF
#!/usr/bin/env bash
set -o pipefail
cd "$WORKSPACE"
${ANTHROPIC_API_KEY:+export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"}
PROMPT=\$(cat "$TASK_FILE")
claude $CLAUDE_FLAGS "\$PROMPT" 2>&1 | tee "$LOG"
echo "RUNNER_EXIT:\${PIPESTATUS[0]}" >> "$LOG"
WRAPPER_EOF
chmod +x "$WRAPPER"

if [ "$(id -u)" -eq 0 ]; then
  if id claude &>/dev/null; then
    chown -R claude:claude "$WORKSPACE" 2>/dev/null || true
    chmod +r "$TASK_FILE" "$WRAPPER"
    TMUX_RUN="su -s /bin/bash claude -c 'bash $WRAPPER'"
  else
    echo "WARNING: no 'claude' user — run setup.sh to create it"
    TMUX_RUN="bash $WRAPPER"
  fi
else
  TMUX_RUN="bash $WRAPPER"
fi

# ── Launch tmux ───────────────────────────────────────────────

TMUX_SOCK="/tmp/tmux-$(id -u)/default"
if [ -S "$TMUX_SOCK" ] && ! tmux list-sessions &>/dev/null 2>&1; then
  rm -f "$TMUX_SOCK"
fi

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" "$TMUX_RUN"

VM_IP=$(hostname -I | awk '{print $1}')
notify "🤖 *Claude runner started*
Branch: \`${BRANCH:-current}\`
Model: \`${MODEL_ID:-default}\`  Effort: \`${EFFORT:-default}\`  MaxTurns: \`${MAX_TURNS}\`

Attach: \`ssh root@${VM_IP}\` → \`tmux attach -t $SESSION\`
Log: \`tail -f $LOG\`"

echo "▶ Claude running in tmux session '$SESSION'"
echo "  Attach: tmux attach -t $SESSION"
echo "  Log:    tail -f $LOG"

# ── Monitor loop ──────────────────────────────────────────────

LAST_SIZE=0
IDLE_SINCE=$(date +%s)
NOTIFIED_IDLE=false
NOTIFIED_TOKEN=false
NOTIFIED_AUTH=false

while tmux has-session -t "$SESSION" 2>/dev/null; do
  sleep 10

  STATUS=$(parse_log "$LOG" 2>/dev/null || echo '{"done":false,"auth_error":false,"token_limit":false}')
  IS_DONE=$(get_field    "$STATUS" done        "false")
  IS_AUTH=$(get_field    "$STATUS" auth_error  "false")
  IS_TOKEN=$(get_field   "$STATUS" token_limit "false")
  STOP_REASON=$(get_field "$STATUS" stop_reason "")
  IS_ERROR=$(get_field   "$STATUS" is_error    "false")
  COST=$(get_field       "$STATUS" cost_usd    "0")
  TURNS=$(get_field      "$STATUS" num_turns   "0")

  # Legacy exit marker fallback (non-stream-json output)
  if grep -q "^RUNNER_EXIT:" "$LOG" 2>/dev/null; then
    IS_DONE="True"
    LEGACY_CODE=$(grep "^RUNNER_EXIT:" "$LOG" | tail -1 | cut -d: -f2 | tr -d '[:space:]')
    [[ "$LEGACY_CODE" != "0" ]] && IS_ERROR="True"
  fi

  # ── Auth error ───────────────────────────────────────────────
  if [[ "$IS_AUTH" =~ ^[Tt]rue$ && "$NOTIFIED_AUTH" == "false" ]]; then
    NOTIFIED_AUTH=true
    notify "🔐 *Auth error — manual login required*
Branch: \`${BRANCH:-current}\`

SSH in and run:
\`\`\`
ssh root@${VM_IP}
su -s /bin/bash claude -c 'claude login'
\`\`\`
Then re-launch runner."
    echo "▶ Auth error — notified, stopping monitor"
    break
  fi

  # ── Token / context limit ────────────────────────────────────
  if [[ "$IS_TOKEN" =~ ^[Tt]rue$ && "$NOTIFIED_TOKEN" == "false" ]]; then
    NOTIFIED_TOKEN=true
    notify "⚠️ *Token/context limit hit*
Branch: \`${BRANCH:-current}\`  Turns: \`${TURNS}\`  Cost: \`\$${COST}\`

Work is saved on branch. To continue:
Re-launch with a prompt like \"Continue from where you left off on branch \`${BRANCH}\`\""
    echo "▶ Token limit — notified, stopping monitor"
    break
  fi

  # ── Session complete ─────────────────────────────────────────
  if [[ "$IS_DONE" =~ ^[Tt]rue$ ]]; then
    if [[ "$IS_ERROR" =~ ^[Tt]rue$ ]]; then
      notify "❌ *Claude failed* (\`${STOP_REASON:-error}\`)
Branch: \`${BRANCH:-current}\`  Cost: \`\$${COST}\`

\`\`\`
$(grep -v '^{' "$LOG" 2>/dev/null | tail -6 || true)
\`\`\`
Attach: \`tmux attach -t $SESSION\`"
      echo "▶ Done (error: ${STOP_REASON:-unknown})"
    else
      diff_review

      PR_URL=""
      if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        CURRENT_HEAD=$(git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$CURRENT_HEAD" == feature/* ]]; then
          COMMIT_TITLE=$(git -C "$WORKSPACE" log -1 --pretty=%s 2>/dev/null || echo "Automated changes")
          REMOTE_URL=$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null || echo "")
          REPO_SLUG=$(echo "$REMOTE_URL" | sed 's|.*github\.com[:/]\(.*\)\.git$|\1|;s|.*github\.com[:/]\(.*\)$|\1|')

          REVIEW_NOTE=""
          [[ "$REVIEW_SAFE" =~ ^[Ff]alse$ ]] && REVIEW_NOTE="⚠️ **Haiku flagged issues** — review before merging.\n\n"

          PR_BODY="${REVIEW_NOTE}Automated PR from claude-runner.

**Model:** \`${MODEL_ID:-default}\` | **Effort:** \`${EFFORT:-default}\` | **Turns:** \`${TURNS}\` | **Cost:** \`\$${COST}\`

**Task:**
$(head -5 "$TASK_FILE")
$(if [[ -n "$REVIEW_SUMMARY" ]]; then printf "\n**Haiku review:** %s" "$REVIEW_SUMMARY"; fi)
$(if [[ -n "$REVIEW_ISSUES"  ]]; then printf "\n\`\`\`\n%s\n\`\`\`"  "$REVIEW_ISSUES";  fi)

---
_Created by claude-runner_"

          PR_URL=$(gh pr create \
            --repo "$REPO_SLUG" \
            --base dev \
            --head "$CURRENT_HEAD" \
            --title "$COMMIT_TITLE" \
            --body "$PR_BODY" 2>/dev/null || echo "")

          [[ -n "$PR_URL" ]] && echo "▶ PR: $PR_URL"
        fi
      else
        echo "▶ Skipping PR (gh not authenticated)"
      fi

      DONE_MSG="✅ *Claude finished*
Branch: \`${BRANCH:-current}\`  Turns: \`${TURNS}\`  Cost: \`\$${COST}\`"
      [[ -n "$PR_URL"         ]] && DONE_MSG+="
PR: ${PR_URL}"
      [[ -n "$REVIEW_SUMMARY" ]] && DONE_MSG+="
Review: _${REVIEW_SUMMARY}_"
      [[ -n "$REVIEW_ISSUES"  ]] && DONE_MSG+="
\`\`\`
${REVIEW_ISSUES}
\`\`\`"
      notify "$DONE_MSG"
      echo "▶ Done (exit 0)"
    fi
    break
  fi

  # ── Idle detection ───────────────────────────────────────────
  CURRENT_SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [[ "$CURRENT_SIZE" -ne "$LAST_SIZE" ]]; then
    LAST_SIZE=$CURRENT_SIZE
    IDLE_SINCE=$(date +%s)
    NOTIFIED_IDLE=false
  else
    IDLE_SECS=$(( $(date +%s) - IDLE_SINCE ))
    if [[ $IDLE_SECS -gt $IDLE_TIMEOUT && "$NOTIFIED_IDLE" == "false" ]]; then
      NOTIFIED_IDLE=true
      notify "⏸ *Claude idle ${IDLE_SECS}s — may need input*
Branch: \`${BRANCH:-current}\`

\`\`\`
$(grep -v '^{' "$LOG" 2>/dev/null | tail -5 || true)
\`\`\`
Attach: \`tmux attach -t $SESSION\`"
      echo "▶ Idle ${IDLE_SECS}s — notified"
    fi
  fi

done
