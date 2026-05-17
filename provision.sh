#!/bin/bash
# Devbox provisioner wizard.
# Run anytime to add modules. Always pulls latest scripts from git first.
set -euo pipefail

DEVBOX_DIR="/opt/devbox"

# Pull latest scripts
if [ -d "$DEVBOX_DIR/.git" ]; then
  echo "▶ Pulling latest devbox scripts..."
  git -C "$DEVBOX_DIR" pull --quiet
fi

MODULES_DIR="$DEVBOX_DIR/modules"
APPS_DIR="$DEVBOX_DIR/apps"

# Discover available modules
mapfile -t MODULE_FILES < <(find "$MODULES_DIR" -name "*.sh" | sort)
mapfile -t APP_FILES    < <(find "$APPS_DIR"   -name "*.sh" | sort)

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Devbox Provisioner"
echo "════════════════════════════════════════════════════════"
echo ""
echo "── Dev tools ────────────────────────────────────────────"
i=1
declare -A MENU
for f in "${MODULE_FILES[@]}"; do
  name=$(basename "$f" .sh)
  desc=$(grep '^# desc:' "$f" 2>/dev/null | sed 's/# desc: //' || echo "$name")
  printf "  [%2d] %-20s %s\n" "$i" "$name" "$desc"
  MENU[$i]="$f"
  ((i++))
done

echo ""
echo "── App environments ─────────────────────────────────────"
for f in "${APP_FILES[@]}"; do
  name=$(basename "$f" .sh)
  desc=$(grep '^# desc:' "$f" 2>/dev/null | sed 's/# desc: //' || echo "$name")
  printf "  [%2d] %-20s %s\n" "$i" "$name" "$desc"
  MENU[$i]="$f"
  ((i++))
done

echo ""
echo "  [a] Install all modules"
echo "  [q] Quit"
echo ""

read -rp "Select (space-separated numbers, or a/q): " SELECTION

if [ "$SELECTION" = "q" ]; then
  exit 0
fi

if [ "$SELECTION" = "a" ]; then
  for f in "${MODULE_FILES[@]}"; do
    echo "▶ Running $(basename "$f")..."
    bash "$f"
  done
else
  for num in $SELECTION; do
    if [ -n "${MENU[$num]+_}" ]; then
      echo "▶ Running $(basename "${MENU[$num]}")..."
      bash "${MENU[$num]}"
    else
      echo "⚠ Unknown option: $num"
    fi
  done
fi

echo ""
echo "✓ Done. Restart your shell: exec zsh"
