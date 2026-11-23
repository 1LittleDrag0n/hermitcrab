"""Make the window look like the rest of the user's desktop.

Run from source with the distro's PySide6, Qt loads the user's real style
(Breeze, Kvantum) by itself — nothing to do. Inside the AppImage the bundled
Qt can't load the system's style plugins, so we fall back to Fusion and copy
the colours, font and icon theme out of ~/.config/kdeglobals instead.
"""

from __future__ import annotations

import os
from pathlib import Path

from PySide6.QtGui import QColor, QFont, QIcon, QPalette
from PySide6.QtWidgets import QApplication

KDEGLOBALS = Path.home() / ".config/kdeglobals"


def _read_kdeglobals() -> dict[str, dict[str, str]]:
    data: dict[str, dict[str, str]] = {}
    try:
        sect = ""
        for raw in KDEGLOBALS.read_text(errors="replace").splitlines():
            line = raw.strip()
            if line.startswith("[") and line.endswith("]"):
                sect = line[1:-1]
                data.setdefault(sect, {})
            elif "=" in line and sect:
                k, v = line.split("=", 1)
                data[sect][k.strip()] = v.strip()
    except OSError:
        pass
    return data


def _color(v: str | None) -> QColor | None:
    if not v:
        return None
    parts = [p for p in v.split(",") if p.strip()]
    try:
        nums = [int(p) for p in parts[:3]]
        return QColor(*nums) if len(nums) == 3 else None
    except ValueError:
        return None


def _palette(kg: dict[str, dict[str, str]]) -> QPalette | None:
    win, view = kg.get("Colors:Window", {}), kg.get("Colors:View", {})
    btn, sel = kg.get("Colors:Button", {}), kg.get("Colors:Selection", {})
    bg = _color(win.get("BackgroundNormal"))
    fg = _color(win.get("ForegroundNormal"))
    if not bg or not fg:
        return None
    pal = QPalette()
    pairs = {
        QPalette.Window: bg, QPalette.WindowText: fg,
        QPalette.Base: _color(view.get("BackgroundNormal")) or bg,
        QPalette.AlternateBase: _color(view.get("BackgroundAlternate")) or bg,
        QPalette.Text: _color(view.get("ForegroundNormal")) or fg,
        QPalette.Button: _color(btn.get("BackgroundNormal")) or bg,
        QPalette.ButtonText: _color(btn.get("ForegroundNormal")) or fg,
        QPalette.Highlight: _color(sel.get("BackgroundNormal")),
        QPalette.HighlightedText: _color(sel.get("ForegroundNormal")),
        QPalette.ToolTipBase: bg, QPalette.ToolTipText: fg,
        QPalette.PlaceholderText: _color(view.get("ForegroundInactive")),
        QPalette.Link: _color(view.get("ForegroundLink")),
    }
    for role, c in pairs.items():
        if c:
            pal.setColor(role, c)
    dis = _color(win.get("ForegroundInactive"))
    if dis:
        for role in (QPalette.WindowText, QPalette.Text, QPalette.ButtonText):
            pal.setColor(QPalette.Disabled, role, dis)
    return pal


def apply(app: QApplication) -> None:
    kg = _read_kdeglobals()
    icon_theme = kg.get("Icons", {}).get("Theme")
    if icon_theme and QIcon.themeName() in ("", "hicolor"):
        QIcon.setThemeSearchPaths([str(Path.home() / ".local/share/icons"),
                                   str(Path.home() / ".icons"), "/usr/share/icons"])
        QIcon.setThemeName(icon_theme)

    in_appimage = bool(os.environ.get("APPIMAGE"))
    native = app.style().name().lower() in ("breeze", "kvantum", "kvantum-dark", "oxygen")
    if native and not in_appimage:
        return
    app.setStyle("Fusion")
    pal = _palette(kg)
    if pal:
        app.setPalette(pal)
    font = kg.get("General", {}).get("font")
    if font:
        f = QFont()
        if f.fromString(font):
            app.setFont(f)
