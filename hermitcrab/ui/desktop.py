"""Add / remove the app-menu launcher.

From the AppImage, the AppImage itself is copied to a stable place first, so
the launcher keeps working even if the downloaded file is later moved or
deleted from ~/Downloads.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from .. import APP_ID, APP_NAME

DATA = Path.home() / ".local/share"
APPS = DATA / "applications"
ICON_DIR = DATA / "icons/hicolor/scalable/apps"
INSTALL_DIR = DATA / "hermitcrab"
DESKTOP = APPS / f"{APP_ID}.desktop"


def icon_path() -> Path | None:
    import sys
    here = Path(__file__).resolve().parent.parent
    bundle = Path(getattr(sys, "_MEIPASS", here))
    for cand in [bundle / "hermitcrab/assets/hermitcrab.svg", here / "assets/hermitcrab.svg"]:
        if cand.is_file():
            return cand
    return None


def is_installed() -> bool:
    return DESKTOP.is_file()


def install() -> str:
    appimage = os.environ.get("APPIMAGE")
    if appimage:
        INSTALL_DIR.mkdir(parents=True, exist_ok=True)
        target = INSTALL_DIR / "HermitCrab.AppImage"
        if Path(appimage).resolve() != target.resolve():
            shutil.copy2(appimage, target)
        target.chmod(0o755)
        exec_line = f'"{target}"'
    else:
        launcher = Path.home() / ".local/bin/hermitcrab"
        exec_line = str(launcher) if launcher.exists() else "hermitcrab"

    ICON_DIR.mkdir(parents=True, exist_ok=True)
    src_icon = icon_path()
    if src_icon:
        shutil.copy2(src_icon, ICON_DIR / "hermitcrab.svg")

    APPS.mkdir(parents=True, exist_ok=True)
    DESKTOP.write_text(f"""[Desktop Entry]
Type=Application
Name={APP_NAME}
GenericName=Desktop Backup & Migration
Comment=Move your whole desktop — themes, widgets, apps — to a new install
Exec={exec_line}
Icon=hermitcrab
Terminal=false
Categories=System;Utility;Settings;
Keywords=backup;restore;migrate;theme;kde;plasma;dotfiles;
StartupWMClass=hermitcrab
""")
    DESKTOP.chmod(0o755)
    if shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(APPS)], capture_output=True)
    if shutil.which("kbuildsycoca6"):
        subprocess.run(["kbuildsycoca6"], capture_output=True)
    return f"{APP_NAME} added to your application menu."


def uninstall() -> str:
    for p in [DESKTOP, ICON_DIR / "hermitcrab.svg", INSTALL_DIR / "HermitCrab.AppImage"]:
        try:
            p.unlink()
        except FileNotFoundError:
            pass
    if shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(APPS)], capture_output=True)
    return f"{APP_NAME} removed from your application menu."
