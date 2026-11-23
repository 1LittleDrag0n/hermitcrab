#!/usr/bin/env bash
# =============================================================================
#  build-appimage.sh — build dist/HermitCrab-<version>-x86_64.AppImage
#
#  Needs: python3 (3.10+), pip, internet (PyPI + GitHub for appimagetool).
#  Runs the same locally and in GitHub Actions.
#
#  Build on the OLDEST distro you want to support: the AppImage needs a glibc
#  at least as new as the one it was built on. CI uses Ubuntu 22.04.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build}"
DIST="$ROOT/dist"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/hermitcrab/__init__.py")"
ARCH=x86_64
OUT="$DIST/HermitCrab-$VERSION-$ARCH.AppImage"

echo "==> HermitCrab $VERSION"
find "$BUILD" -mindepth 1 -maxdepth 1 ! -name appimagetool -exec rm -rf {} +
mkdir -p "$BUILD" "$DIST"

# ── 1. isolated build environment ─────────────────────────────────────────────
python3 -m venv "$BUILD/venv"
# shellcheck disable=SC1091
. "$BUILD/venv/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$ROOT/packaging/requirements-build.txt"

# ── 2. freeze the app ────────────────────────────────────────────────────────
# Only the Qt modules HermitCrab imports are pulled in; QML/Quick/WebEngine
# are excluded explicitly to keep the AppImage small.
pyinstaller --noconfirm --clean --log-level WARN \
    --name hermitcrab \
    --distpath "$BUILD/pyi-dist" --workpath "$BUILD/pyi-work" --specpath "$BUILD" \
    --paths "$ROOT" \
    --add-data "$ROOT/scripts:scripts" \
    --add-data "$ROOT/hermitcrab/assets:hermitcrab/assets" \
    --exclude-module PySide6.QtQml --exclude-module PySide6.QtQuick \
    --exclude-module PySide6.QtQuickWidgets --exclude-module PySide6.QtWebEngineCore \
    --exclude-module PySide6.QtWebEngineWidgets --exclude-module PySide6.QtPdf \
    --exclude-module PySide6.QtMultimedia --exclude-module PySide6.Qt3DCore \
    --exclude-module tkinter \
    "$ROOT/packaging/entry.py"
deactivate

# ── 3. assemble the AppDir ───────────────────────────────────────────────────
APPDIR="$BUILD/AppDir"
mkdir -p "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/scalable/apps"
cp -a "$BUILD/pyi-dist/hermitcrab" "$APPDIR/usr/lib/hermitcrab"
chmod +x "$APPDIR/usr/lib/hermitcrab/_internal/scripts/"*.sh
install -m755 "$ROOT/packaging/AppRun" "$APPDIR/AppRun"
install -m644 "$ROOT/packaging/hermitcrab.desktop" "$APPDIR/hermitcrab.desktop"
install -m644 "$ROOT/packaging/hermitcrab.desktop" "$APPDIR/usr/share/applications/"
install -m644 "$ROOT/hermitcrab/assets/hermitcrab.svg" "$APPDIR/hermitcrab.svg"
install -m644 "$ROOT/hermitcrab/assets/hermitcrab.svg" \
    "$APPDIR/usr/share/icons/hicolor/scalable/apps/hermitcrab.svg"
ln -sf hermitcrab.svg "$APPDIR/.DirIcon"

# ── 4. pack ──────────────────────────────────────────────────────────────────
TOOL="$BUILD/appimagetool"
if [ ! -x "$TOOL" ]; then
    curl -fsSL -o "$TOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
    chmod +x "$TOOL"
fi
# --appimage-extract-and-run: works without FUSE (containers, CI)
ARCH=$ARCH "$TOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUT"

echo ""
echo "==> Built: $OUT ($(du -h "$OUT" | cut -f1))"
