#!/bin/bash
# Base dev VM setup — idempotent, safe to re-run.
# Run as root on a fresh Debian 12 LXC.
set -euo pipefail

DEVBOX_REPO="https://github.com/junoput/devbox"
DEVBOX_RAW="https://raw.githubusercontent.com/junoput/devbox/main"
DEVBOX_DIR="/opt/devbox"

log()  { echo "▶ $*"; }
ok() { echo "✓ $*"; }

# ── System ────────────────────────────────────────────────────────────────────
log "Updating system packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "system updated"

# ── Core tools ────────────────────────────────────────────────────────────────
log "Installing core tools"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git curl wget ca-certificates gnupg \
  zsh tmux neovim \
  ripgrep fzf jq \
  htop btop \
  build-essential pkg-config \
  python3 python3-pip python3-venv \
  direnv rsync unzip zip \
  openssh-client openssh-server \
  sqlite3 \
  2>/dev/null
ok "core tools installed"

# ── yq ────────────────────────────────────────────────────────────────────────
if ! command -v yq &>/dev/null; then
  log "Installing yq"
  curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq
  ok "yq installed"
fi

# ── GitHub CLI ────────────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  log "Installing gh CLI"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq && apt-get install -y gh 2>/dev/null
  ok "gh installed"
fi

# ── Node.js (LTS via NodeSource) ──────────────────────────────────────────────
if ! command -v node &>/dev/null; then
  log "Installing Node.js LTS"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - 2>/dev/null
  apt-get install -y nodejs 2>/dev/null
  ok "node installed"
fi

# ── Claude Code ───────────────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  log "Installing Claude Code"
  npm install -g @anthropic-ai/claude-code 2>/dev/null
  ok "claude code installed"
fi

# ── Caveman plugin ────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.claude/hooks/caveman-activate.js" ]; then
  log "Installing caveman plugin"
  curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash
  ok "caveman installed"
fi

# ── Podman ────────────────────────────────────────────────────────────────────
if ! command -v podman &>/dev/null; then
  log "Installing Podman"
  apt-get install -y podman podman-compose fuse-overlayfs 2>/dev/null
  # LXC config
  mkdir -p /etc/containers
  cat > /etc/containers/registries.conf << 'EOF'
unqualified-search-registries = ["docker.io"]
EOF
  cat > /etc/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
  echo 'export BUILDAH_ISOLATION=chroot' > /etc/profile.d/buildah.sh
  ok "podman installed"
fi

# ── zsh + oh-my-zsh ──────────────────────────────────────────────────────────
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  log "Installing oh-my-zsh"
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" 2>/dev/null
  ok "oh-my-zsh installed"
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
  log "Installing zsh-autosuggestions"
  git clone --quiet https://github.com/zsh-users/zsh-autosuggestions \
    "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
  log "Installing zsh-syntax-highlighting"
  git clone --quiet https://github.com/zsh-users/zsh-syntax-highlighting \
    "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

# Write .zshrc
cat > "$HOME/.zshrc" << 'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting fzf direnv)
source $ZSH/oh-my-zsh.sh

# Env
export EDITOR=nvim
export PATH="$HOME/.local/bin:$PATH"

# Aliases
alias ll='ls -lah'
alias gs='git status'
alias gp='git pull'
alias dc='podman-compose'
alias ports='ss -tlnp'

# fzf
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# direnv
eval "$(direnv hook zsh)"
EOF

# Set zsh as default shell
chsh -s "$(which zsh)" root
ok "zsh configured"

# ── tmux config ───────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.tmux.conf" ]; then
  cat > "$HOME/.tmux.conf" << 'EOF'
set -g default-shell /bin/zsh
set -g mouse on
set -g history-limit 10000
set -g base-index 1
set-option -g status-style bg=colour235,fg=white
bind r source-file ~/.tmux.conf \; display "Config reloaded"
EOF
fi

# ── GitHub SSH key ────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  log "Generating GitHub SSH key"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "devbox@$(hostname)"
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  Add this public key to github.com/settings/keys:"
  echo "════════════════════════════════════════════════════════"
  cat "$HOME/.ssh/id_ed25519.pub"
  echo "════════════════════════════════════════════════════════"
  echo ""
  read -rp "Press Enter once you've added the key to GitHub... "
  # Verify
  ssh -T git@github.com 2>&1 | grep -q "successfully authenticated" && \
    echo "✓ GitHub SSH auth working" || \
    echo "⚠ GitHub auth not confirmed — add key and test manually: ssh -T git@github.com"
fi

# ── claude user (runs Claude Code — blocked as root with --dangerously-skip-permissions) ──
if ! id claude &>/dev/null; then
  log "Creating claude user"
  useradd -m -s /bin/bash claude
fi
# Ensure SSH key copied (needed for git push to GitHub)
mkdir -p /home/claude/.ssh && chmod 700 /home/claude/.ssh
cp "$HOME/.ssh/id_ed25519" /home/claude/.ssh/id_ed25519
cp "$HOME/.ssh/id_ed25519.pub" /home/claude/.ssh/id_ed25519.pub
[ -f "$HOME/.ssh/known_hosts" ] && cp "$HOME/.ssh/known_hosts" /home/claude/.ssh/known_hosts
chown -R claude:claude /home/claude/.ssh && chmod 600 /home/claude/.ssh/id_ed25519
# Git config
su -s /bin/bash claude -c '
  git config --global user.email "claude@devbox"
  git config --global user.name "Claude Dev"
  git config --global core.editor nvim
  git config --global init.defaultBranch main
  git config --global pull.rebase false
'
# Copy gh credentials if root is authenticated
if [ -f "$HOME/.config/gh/hosts.yml" ]; then
  mkdir -p /home/claude/.config/gh
  cp "$HOME/.config/gh/hosts.yml" /home/claude/.config/gh/hosts.yml
  chown -R claude:claude /home/claude/.config/gh
  chmod 600 /home/claude/.config/gh/hosts.yml
fi
ok "claude user ready"

# ── Clone/update devbox repo ──────────────────────────────────────────────────
if [ -d "$DEVBOX_DIR/.git" ]; then
  log "Updating devbox scripts"
  git -C "$DEVBOX_DIR" pull --quiet
else
  log "Cloning devbox scripts"
  git clone --quiet "$DEVBOX_REPO" "$DEVBOX_DIR"
fi
chmod +x "$DEVBOX_DIR"/**/*.sh 2>/dev/null || true
ok "devbox scripts at $DEVBOX_DIR"

# ── Git global config ─────────────────────────────────────────────────────────
git config --global core.editor nvim
git config --global init.defaultBranch main
git config --global pull.rebase false

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Base setup complete."
echo "  Run 'bash /opt/devbox/provision.sh' to add more tools."
echo "  Switch to zsh: exec zsh"
echo "════════════════════════════════════════════════════════"
