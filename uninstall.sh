#!/usr/bin/env bash
# Remove a source install of HermitCrab (and its app-menu entry).
# Your presets in ~/.config/hermitcrab are kept unless you pass --purge.
set -euo pipefail

BIN="$HOME/.local/bin/hermitcrab"
if [ -x "$BIN" ]; then
    "$BIN" --uninstall-desktop || true
fi
rm -f "$BIN"
rm -rf "$HOME/.local/share/hermitcrab"
rm -f "$HOME/.local/share/applications/io.github.hermitcrab.desktop" \
      "$HOME/.local/share/icons/hicolor/scalable/apps/hermitcrab.svg"
if [ "${1:-}" = "--purge" ]; then
    rm -rf "$HOME/.config/hermitcrab"
    echo "Presets removed too."
fi
command -v update-desktop-database >/dev/null && \
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "HermitCrab removed."
