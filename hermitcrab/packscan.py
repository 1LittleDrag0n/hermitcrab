"""Scan a backup or theme pack (already extracted) for the restore screen.

Every leaf is either a path inside the pack (kind=pack: unticking it deletes
it from a hard-linked working copy before restore runs) or a package name
(unticking drops it from the package list the restore installs).
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Callable

from . import sysinfo
from .model import PACK, PACKAGE, FLATPAK, Item, ScanResult

Progress = Callable[[str, int], None]


def _ls(d: Path) -> list[Path]:
    try:
        return sorted(d.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        return []


def read_manifest(pack: Path) -> dict[str, str]:
    out = {}
    try:
        for line in (pack / "MANIFEST").read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


class PackScanner:
    def __init__(self, pack_dir: str, progress: Progress | None = None):
        self.pack = Path(pack_dir)
        self.progress = progress or (lambda m, p: None)

    def _leaf(self, parent: Item, path: Path, label: str | None = None,
              private: bool = False, default: bool = True, note: str = "") -> Item | None:
        if not os.path.lexists(path):
            return None
        rel = str(path.relative_to(self.pack))
        return parent.add(Item(id=f"pack:{rel}", label=label or path.name, kind=PACK,
                               paths=[str(path)], private=private, default=default,
                               note=note))

    def _children(self, parent: Item, folder: Path, private: bool = False,
                  note_fn=None) -> None:
        for p in _ls(folder):
            self._leaf(parent, p, private=private, note=note_fn(p) if note_fn else "")

    def _group(self, roots: list[Item], label: str) -> Item:
        g = Item(id=f"group:{label}", label=label)
        roots.append(g)
        return g

    def run(self) -> ScanResult:
        P = self.pack
        man = read_manifest(P)
        mode = man.get("TYPE", "unknown")
        roots: list[Item] = []
        warnings: list[str] = []
        self.progress("Reading pack…", 10)

        # ── settings ─────────────────────────────────────────────────────────
        g = self._group(roots, "Plasma settings")
        for base in [P / "config", P / "kde-config/config", P / "kde-config/dirs"]:
            self._children(g, base, note_fn=lambda p: "")
        for sub in ["konsole", "kxmlgui5", "kservices5"]:
            self._leaf(g, P / "kde-config" / sub)
        self._leaf(g, P / "kde-config/kwalletd", "KDE Wallet (saved passwords)", private=True)
        for p in g.children:
            if p.label in ("kwalletrc", "kwallet5rc", "kdeconnect"):
                p.private = True

        # ── themes ───────────────────────────────────────────────────────────
        g = self._group(roots, "Themes")
        for sub, label in [("look-and-feel", "Global themes"), ("desktoptheme", "Plasma styles"),
                           ("aurorae/themes", "Window decorations"),
                           ("color-schemes", "Colour schemes"), ("Kvantum", "Kvantum themes"),
                           ("Kvantum-local", "Kvantum themes (local)"),
                           ("kstyle", "Widget styles")]:
            d = P / "themes" / sub
            if d.is_dir() and _ls(d):
                sg = g.add(Item(id=f"group:pthemes:{sub}", label=label))
                self._children(sg, d)
        su = P / "themes/system-unowned"
        if su.is_dir():
            sg = g.add(Item(id="group:pthemes:system", label="System-wide themes"))
            for top in _ls(su):
                for leaf in _ls(top) if top.is_dir() else []:
                    if leaf.is_dir() and leaf.name in ("themes",):
                        for x in _ls(leaf):
                            self._leaf(sg, x)
                    else:
                        self._leaf(sg, leaf)

        # ── icons ────────────────────────────────────────────────────────────
        g = self._group(roots, "Icons & cursors")
        for sub in ["local-icons", "local-share-icons", "dot-icons", "system-unowned"]:
            self._children(g, P / "icons" / sub,
                           note_fn=lambda p: "cursor theme" if (p / "cursors").is_dir() else "")

        g = self._group(roots, "Fonts")
        self._children(g, P / "fonts")

        g = self._group(roots, "Login screen")
        self._children(g, P / "sddm/themes", note_fn=lambda p: "login theme")
        for f in ["sddm.conf", "sddm.conf.d"]:
            self._leaf(g, P / "sddm" / f, "Login screen settings" if f == "sddm.conf.d" else f)

        # ── widgets ──────────────────────────────────────────────────────────
        g = self._group(roots, "Widgets & effects")
        for sub, label in [("files", "Widgets"), ("kwin-scripts", "KWin scripts"),
                           ("kwin-effects", "KWin effects"),
                           ("kwin-effects-files", "KWin effects (QML)")]:
            d = P / "widgets" / sub
            if d.is_dir() and _ls(d):
                sg = g.add(Item(id=f"group:pwidgets:{sub}", label=label))
                self._children(sg, d)

        g = self._group(roots, "GTK")
        self._children(g, P / "gtk")

        g = self._group(roots, "Wallpapers")
        wp = P / "wallpapers"
        self._children(g, wp / "Pictures")
        self._leaf(g, wp / "local-wallpapers", "Wallpaper collection")
        for f in _ls(wp):
            if f.is_file() and f.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp", ".gif"):
                self._leaf(g, f)

        g = self._group(roots, "Spotify theme")
        self._children(g, P / "spicetify")

        g = self._group(roots, "Customization tools")
        for sub in ["config", "local-share", "bin", "systemd-user", "manual"]:
            d = P / "extras" / sub
            if sub in ("bin", "systemd-user", "manual"):
                self._leaf(g, d, {"bin": "Scripts (~/.local/bin)",
                                  "systemd-user": "Theming services",
                                  "manual": "Manually included paths"}[sub])
            else:
                self._children(g, d)

        # ── apps (migrate) ───────────────────────────────────────────────────
        g = self._group(roots, "App settings & data")
        extra = P / "apps/extra/home"
        for top in [".config", ".local/share", ".cache", ".var/app"]:
            d = extra / top
            for p in _ls(d):
                self._leaf(g, p, f"~/{top}/{p.name}", default=top != ".cache")
        for p in _ls(extra):
            if p.name not in (".config", ".local", ".cache", ".var"):
                self._leaf(g, p, f"~/{p.name}")
        self._children(g, P / "apps/config")

        g = self._group(roots, "Shell & dotfiles")
        self._children(g, P / "apps/home")
        self._leaf(g, P / "apps/local/bin", "Scripts (~/.local/bin)")
        self._leaf(g, P / "apps/local/mime", "Custom file types")

        g = self._group(roots, "Browsers")
        for b in _ls(P / "browsers"):
            bg = g.add(Item(id=f"group:pbrowser:{b.name}", label=b.name.title()))
            for prof in _ls(b):
                if prof.is_dir():
                    self._leaf(bg, prof, private=True)

        g = self._group(roots, "Network & keys")
        self._leaf(g, P / "network/nm-connections", "WiFi & VPN passwords", private=True)
        self._leaf(g, P / "keys/ssh", "SSH keys", private=True, default=True)
        gpg = P / "keys/gpg-private.asc"
        if gpg.exists():
            self._leaf(g, gpg, "GPG keys", private=True)
        power = [p for p in ["tlp.conf", "auto-cpufreq.conf"] if (P / "network" / p).exists()]
        for p in power:
            self._leaf(g, P / "network" / p, f"Power settings ({p})")

        g = self._group(roots, "System")
        self._leaf(g, P / "misc/systemd-user", "Your background services")
        self._leaf(g, P / "misc/environment.d", "Environment variables")
        self._leaf(g, P / "misc/crontab.txt", "Scheduled jobs (crontab)")
        self._leaf(g, P / "misc/user-dirs.dirs", "Folder locations")

        # ── packages ─────────────────────────────────────────────────────────
        self.progress("Reading package lists…", 50)
        g = self._group(roots, "Packages to install")
        for base, files in [(P / "dependencies", [("native.txt", "From the repos", PACKAGE),
                                                  ("aur.txt", "From the AUR", PACKAGE)]),
                            (P / "packages", [("native.txt", "From the repos", PACKAGE),
                                              ("aur.txt", "From the AUR", PACKAGE),
                                              ("flatpak.txt", "Flatpak apps", FLATPAK)])]:
            for fname, label, kind in files:
                f = base / fname
                if not f.is_file():
                    continue
                names = [l.strip() for l in f.read_text(errors="replace").splitlines()
                         if l.strip() and not l.startswith("#")]
                if not names:
                    continue
                sg = g.add(Item(id=f"group:ppkgs:{base.name}/{fname}", label=label,
                                note=f"{len(names)} packages"))
                for n in names:
                    sg.add(Item(id=f"pkg:{n}", label=n, kind=kind, packages=[n],
                                note=f"{base.name}/{fname}"))

        # drop empty groups (recursively)
        def prune(it: Item) -> bool:
            it.children = [c for c in it.children if prune(c)]
            return it.kind != "group" or bool(it.children)
        roots = [r for r in roots if prune(r)]

        # ── warnings ─────────────────────────────────────────────────────────
        src_pl = man.get("PLASMA", "")
        cur_pl = sysinfo.plasma_version()
        info = {"type": mode, "plasma_pack": src_pl, "plasma_here": cur_pl,
                "manifest": man, "version_mismatch": False}
        if src_pl and cur_pl and src_pl.split(".")[0] != cur_pl.split(".")[0]:
            info["version_mismatch"] = True
            warnings.append(f"This pack was made on Plasma {src_pl}, this system runs "
                            f"Plasma {cur_pl}. Themes and widgets will probably break.")
        for name in ["EXTERNAL-SETUPS.txt", "TIER3-REPORT"]:
            f = P / name
            if f.exists():
                warnings.append("Part of this desktop comes from a project with its own "
                                "installer. Install that first — details in "
                                f"{name} inside the pack.")
                break
        if mode == "migrate":
            warnings.append("This is a full personal backup: it can contain WiFi passwords, "
                            "SSH/GPG keys and browser data. Only restore it on your own machine.")

        self.progress("Measuring sizes…", 70)
        leaves = [l for r in roots for l in r.leaves() if l.paths]
        sizes = sysinfo.du_bytes([p for l in leaves for p in l.paths])
        for l in leaves:
            l.size = sum(sizes.get(p, 0) for p in l.paths)
        self.progress("Done", 100)
        return ScanResult(mode="restore", roots=roots, warnings=warnings, info=info)
