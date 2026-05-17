# desc: Python dev tools (pyenv, poetry, pipx)
set -euo pipefail

# pyenv
if ! command -v pyenv &>/dev/null; then
  echo "▶ Installing pyenv"
  apt-get install -y --no-install-recommends \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libncursesw5-dev xz-utils libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev 2>/dev/null
  curl -fsSL https://pyenv.run | bash 2>/dev/null
  cat >> /root/.zshrc << 'EOF'
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF
  echo "✓ pyenv installed"
else
  echo "✓ pyenv already installed"
fi

# pipx
if ! command -v pipx &>/dev/null; then
  echo "▶ Installing pipx"
  apt-get install -y pipx 2>/dev/null || pip3 install --user pipx
  pipx ensurepath
fi

# poetry
if ! command -v poetry &>/dev/null; then
  echo "▶ Installing poetry"
  pipx install poetry
  echo "✓ poetry installed"
fi

echo "✓ Python dev tools ready. Reload shell to activate pyenv."
