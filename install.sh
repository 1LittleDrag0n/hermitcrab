#!/usr/bin/env bash
# =============================================================================
#  install.sh — install HermitCrab from source for the current user
#
#  Uses your distro's PySide6, so the window follows your real KDE theme
#  (Breeze / Kvantum). No root needed except to install missing packages.
#
#  Installs to:
#    ~/.local/share/hermitcrab/app        the program
#    ~/.local/bin/hermitcrab              command to start it
#    ~/.local/share/applications/…        app-menu entry
#
#  Remove with ./uninstall.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/hermitcrab/app"
BIN="$HOME/.local/bin/hermitcrab"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }

# ── dependencies ─────────────────────────────────────────────────────────────
# PySide6 is required. rsync is recommended: with it, unticked caches are
# skipped during the copy instead of copied and then deleted.
need=()
python3 -c 'import PySide6' 2>/dev/null || need+=(pyside6)
command -v rsync >/dev/null || need+=(rsync)

if [ ${#need[@]} -gt 0 ]; then
    if command -v pacman >/dev/null; then
        say "Installing: ${need[*]} (official Arch repos)"
        # -S --needed only: never -Sy on its own, that's a partial upgrade
        sudo pacman -S --needed "${need[@]}"
    elif ! python3 -c 'import PySide6' 2>/dev/null; then
        warn "PySide6 is missing. Install it with your package manager,"
        warn "or: pip install --user PySide6-Essentials"
        exit 1
    else
        warn "rsync not found — HermitCrab still works, but large unticked"
        warn "folders are copied and then removed instead of skipped."
    fi
fi

# ── copy the program ─────────────────────────────────────────────────────────
say "Installing to $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$ROOT/hermitcrab" "$ROOT/scripts" "$DEST/"
find "$DEST" -name __pycache__ -prune -exec rm -rf {} +
chmod +x "$DEST/scripts/"*.sh

mkdir -p "$(dirname "$BIN")"
cat > "$BIN" <<EOF
#!/bin/sh
PYTHONPATH="$DEST\${PYTHONPATH:+:\$PYTHONPATH}" exec python3 -m hermitcrab "\$@"
EOF
chmod +x "$BIN"

# ── app menu entry ───────────────────────────────────────────────────────────
"$BIN" --install-desktop

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "~/.local/bin is not in your PATH — the app menu entry still works." ;;
esac

say "Done. Open HermitCrab from your application menu, or run: hermitcrab"
