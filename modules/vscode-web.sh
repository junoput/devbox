# desc: VS Code in browser (code-server) on port 8080
set -euo pipefail

if command -v code-server &>/dev/null; then
  echo "✓ code-server already installed ($(code-server --version | head -1))"
  exit 0
fi

echo "▶ Installing code-server"
curl -fsSL https://code-server.dev/install.sh | sh 2>/dev/null

# Systemd service
systemctl enable --now code-server@root

# Config: no auth on LAN (secured by network), bind all interfaces
mkdir -p /root/.config/code-server
cat > /root/.config/code-server/config.yaml << 'EOF'
bind-addr: 0.0.0.0:8080
auth: none
cert: false
EOF

systemctl restart code-server@root
echo "✓ code-server running at http://$(hostname -I | awk '{print $1}'):8080"
