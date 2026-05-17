# desc: C/C++ dev tools (cmake, ninja, gdb, valgrind, clangd)
set -euo pipefail

echo "▶ Installing C/C++ tools"
apt-get install -y --no-install-recommends \
  cmake ninja-build gdb valgrind \
  clang clang-format clangd \
  lldb libasan6 \
  2>/dev/null

echo "✓ C/C++ tools installed"
echo "  cmake, ninja, gdb, valgrind, clang, clangd"
