# desc: Rust toolchain (rustup, cargo, rust-analyzer)
set -euo pipefail

if command -v rustup &>/dev/null; then
  echo "✓ rust already installed ($(rustc --version))"
  rustup update stable 2>/dev/null
  exit 0
fi

echo "▶ Installing Rust via rustup"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path 2>/dev/null

# Add to zshrc if not already there
if ! grep -q 'cargo/env' /root/.zshrc; then
  echo 'source "$HOME/.cargo/env"' >> /root/.zshrc
fi

source "$HOME/.cargo/env"

# Useful components
rustup component add rust-analyzer clippy rustfmt 2>/dev/null

echo "✓ Rust $(rustc --version) installed"
echo "  Reload shell: source \$HOME/.cargo/env"
