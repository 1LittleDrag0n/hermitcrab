"""Scan this machine for everything a backup could carry.

Produces a tree of Items that mirrors what kde-migrate.sh / kde-themepack.sh
copy, plus every installed app grouped with its settings, data and cache.

Desktop-specific parts live in ``_scan_plasma_*`` so other desktops can be
added later without touching the app/browser/system sections.
"""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path
from typing import Callable

from . import appmap, sysinfo
from .model import (COVERED, EXTRA, FLATPAK, GROUP, PACKAGE, VIRTUAL, Item,
                    ScanResult)

Progress = Callable[[str, int], None]

HOME = Path.home()

# ~/.config entries that kde-migrate.sh copies in its Plasma section
PLASMA_CONFIG_FILES = [
    "plasmarc", "plasma-org.kde.plasma.desktop-appletsrc", "plasmashellrc",
    "kwinrc", "kwinrulesrc", "kdeglobals", "kcminputrc", "kglobalshortcutsrc",
    "kscreenlockerrc", "ksmserverrc", "ksplashrc", "breezerc", "kxkbrc",
    "khotkeysrc", "kded5rc", "kded6rc", "dolphinrc", "konsolerc", "spectaclerc",
    "krunnerrc", "kwalletrc", "kwallet5rc", "mimeapps.list", "kiorc",
    "powerdevilrc", "kactivitymanagerdrc", "plasmanotifyrc", "systemsettingsrc",
    "kfontinstuirc", "gtkrc", "gtkrc-2.0",
]
PLASMA_CONFIG_DIRS = ["plasma-workspace", "kde.org", "systemsettings", "kdeconnect",
                      "autostart", "kglobalaccel", "kdedefaults", "menus"]
PLASMA_LOCAL_DIRS = ["konsole", "kxmlgui5", "kservices5", "kwalletd"]

# Subset kde-themepack.sh ships — appearance only
THEMEPACK_CONFIG_FILES = ["plasmarc", "plasma-org.kde.plasma.desktop-appletsrc",
                          "plasmashellrc", "kwinrc", "kdeglobals", "kcminputrc",
                          "ksplashrc", "kscreenlockerrc", "breezerc"]

FRIENDLY = {
    "plasma-org.kde.plasma.desktop-appletsrc": "Panels & widget layout",
    "kdeglobals": "Colours, fonts, icons (global settings)",
    "kwinrc": "Window manager & effects",
    "kwinrulesrc": "Window rules",
    "kglobalshortcutsrc": "Keyboard shortcuts",
    "kcminputrc": "Mouse, cursor & keyboard",
    "plasmarc": "Plasma style",
    "plasmashellrc": "Plasma shell",
    "kscreenlockerrc": "Lock screen",
    "ksplashrc": "Splash screen",
    "kxkbrc": "Keyboard layouts",
    "kwalletrc": "KDE Wallet settings",
    "kwallet5rc": "KDE Wallet settings (5)",
    "kdeconnect": "KDE Connect pairings",
    "kwalletd": "KDE Wallet (saved passwords)",
    "autostart": "Autostart apps",
    "dolphinrc": "Dolphin",
    "konsolerc": "Konsole",
    "konsole": "Konsole profiles & colours",
    "mimeapps.list": "Default apps / file associations",
    "powerdevilrc": "Power management",
}
PRIVATE_NAMES = {"kwalletrc", "kwallet5rc", "kdeconnect", "kwalletd"}

DOTFILES = [".bashrc", ".bash_profile", ".bash_aliases", ".bash_logout", ".zshrc",
            ".zprofile", ".zshenv", ".zlogin", ".profile", ".inputrc", ".gitconfig",
            ".gitignore_global", ".tmux.conf", ".vimrc", ".editorconfig",
            ".Xresources", ".xinitrc"]

RICE_CONFIG = ["quickshell", "caelestia", "ags", "eww", "waybar", "hypr", "hyprpanel",
               "matugen", "kde-material-you-colors", "wallust", "pywal", "swww",
               "hyprpaper", "azote", "variety", "fuzzel", "rofi", "wofi", "tofi",
               "anyrun", "dunst", "mako", "swaync", "cava", "fastfetch", "neofetch",
               "keyd", "polonium", "darkly", "conky", "picom"]
TIER3_MARKERS = {
    "quickshell": "Quickshell (replaces Plasma panels entirely)",
    "caelestia": "Caelestia dots — has its own setup.sh",
    "ags": "AGS shell", "eww": "EWW widgets", "hypr": "Hyprland config",
}

# Hidden home folders that are toolchains/caches — re-installable, start unticked
REDOWNLOADABLE_DOTDIRS = {".cargo", ".rustup", ".npm", ".gradle", ".m2", ".wine",
                          ".nv", ".pyenv", ".nvm", ".bun", ".deno", ".conda",
                          ".android", ".ollama", ".docker", ".cache", ".java",
                          ".dotnet", ".nuget", ".vscode-server", ".lmstudio"}
# Hidden home folders handled by other sections — never listed in "Other"
HANDLED_DOTDIRS = {".config", ".local", ".cache", ".ssh", ".gnupg", ".mozilla",
                   ".zen", ".icons", ".themes", ".fonts", ".var", ".pki",
                   ".snapshots", ".Trash", ".dbus", ".gtkrc-2.0"} | set(DOTFILES)
BIG = 10 * 1024 ** 3      # >10 GB folders start unticked
MEDIUM = 500 * 1024 ** 2  # >500 MB re-downloadable folders start unticked

IMAGE_RE = re.compile(r"\.(jpe?g|png|webp|gif|mp4)$", re.I)


def _h(p: str) -> str:
    return os.path.expanduser(p)


def _short(p: str) -> str:
    s = str(p)
    h = str(HOME)
    return "~" + s[len(h):] if s.startswith(h) else s


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


def _ls(d: Path) -> list[Path]:
    try:
        return sorted(d.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        return []


def _dirs(d: Path) -> list[Path]:
    return [p for p in _ls(d) if p.is_dir()]


class Scanner:
    def __init__(self, mode: str, progress: Progress | None = None):
        assert mode in ("migrate", "themepack")
        self.mode = mode
        self.progress = progress or (lambda msg, pct: None)
        self.warnings: list[str] = []
        self.claimed: set[str] = set()     # paths already shown somewhere
        self.owners: dict[str, str] = {}
        self.have_pacman = bool(shutil.which("pacman"))

    # ── helpers ──────────────────────────────────────────────────────────────
    def _path_item(self, parent: Item, path: str | Path, label: str | None = None,
                   kind: str = COVERED, default: bool = True, private: bool = False,
                   note: str = "") -> Item | None:
        p = str(path)
        if not os.path.lexists(p):
            return None
        self.claimed.add(p)
        name = label or Path(p).name
        return parent.add(Item(id=f"{kind}:{p}", label=name, kind=kind, paths=[p],
                               default=default, private=private, note=note))

    def _unowned(self, dirs: list[Path]) -> list[Path]:
        # Without pacman we can't tell hand-installed from packaged — list nothing
        # rather than guess (and ship a whole system icon theme by mistake).
        if not self.have_pacman:
            return []
        return [d for d in dirs if str(d).rstrip("/") not in self.owners]

    def _extra_folder(self, parent: Item, path: str | Path, label: str | None = None,
                      default: bool = True, note: str = "") -> None:
        """An app folder, split so huge sub-folders (game libraries, render
        caches) appear as their own unticked child."""
        p = str(path)
        heavy = [(appmap.HEAVY_SUBDIRS[h], _h(h)) for h in appmap.HEAVY_SUBDIRS
                 if _h(h).startswith(p + "/") and os.path.exists(_h(h))]
        if not heavy:
            self._path_item(parent, p, label, kind=EXTRA, default=default, note=note)
            return
        g = parent.add(Item(id=f"group:split:{p}", label=label or Path(p).name, note=note))
        self._path_item(g, p, "Everything else", kind=EXTRA, default=default, note=_short(p))
        for why, hp in heavy:
            self._path_item(g, hp, Path(hp).name, kind=EXTRA, default=False, note=why)

    # ── main ─────────────────────────────────────────────────────────────────
    def run(self) -> ScanResult:
        self.progress("Reading package database…", 3)
        system_dirs: list[str] = []
        for base in ["/usr/share/plasma/desktoptheme", "/usr/share/plasma/look-and-feel",
                     "/usr/share/aurorae/themes", "/usr/share/color-schemes",
                     "/usr/share/Kvantum", "/usr/share/icons", "/usr/share/sddm/themes"]:
            system_dirs += [str(d) for d in _dirs(Path(base))]
        desktop_files = [str(p) for p in Path("/usr/share/applications").glob("*.desktop")]
        self.owners = sysinfo.pacman_owners(system_dirs + desktop_files)

        roots: list[Item] = []
        steps = [
            ("Plasma settings", self._scan_plasma_settings),
            ("Themes", self._scan_plasma_themes),
            ("Icons & cursors", self._scan_icons),
            ("Fonts", self._scan_fonts),
            ("Login screen", self._scan_sddm),
            ("Widgets & effects", self._scan_widgets),
            ("GTK", self._scan_gtk),
            ("Wallpapers", self._scan_wallpapers),
        ]
        if self.mode == "themepack":
            steps += [("Spotify theme", self._scan_spicetify),
                      ("Customization tools", self._scan_rice)]
        else:
            steps += [("Installed apps", self._scan_apps),
                      ("Shell & dotfiles", self._scan_dotfiles),
                      ("Browsers", self._scan_browsers),
                      ("Network & keys", self._scan_private),
                      ("System", self._scan_system),
                      ("Other folders", self._scan_leftovers)]

        for i, (name, fn) in enumerate(steps):
            self.progress(f"Scanning {name.lower()}…", 5 + int(60 * i / len(steps)))
            root = Item(id=f"group:{name}", label=name)
            fn(root)
            if root.children:
                roots.append(root)

        self._detect_tier3()
        self.progress("Measuring sizes…", 70)
        self._fill_sizes(roots)
        self.progress("Done", 100)
        return ScanResult(mode=self.mode, roots=roots, warnings=self.warnings,
                          info={"plasma": sysinfo.plasma_version()})

    # ── Plasma ───────────────────────────────────────────────────────────────
    def _scan_plasma_settings(self, root: Item) -> None:
        cfg = HOME / ".config"
        files = THEMEPACK_CONFIG_FILES if self.mode == "themepack" else PLASMA_CONFIG_FILES
        for f in dict.fromkeys(files):
            self._path_item(root, cfg / f, FRIENDLY.get(f, f),
                            private=f in PRIVATE_NAMES, note=f if f in FRIENDLY else "")
        if self.mode == "themepack":
            for d in ["Kvantum", "plasma-workspace"]:
                self._path_item(root, cfg / d, FRIENDLY.get(d, d))
            self._path_item(root, HOME / ".local/share/konsole", FRIENDLY["konsole"])
            return
        for d in PLASMA_CONFIG_DIRS:
            self._path_item(root, cfg / d, FRIENDLY.get(d, d), private=d in PRIVATE_NAMES,
                            note=d if d in FRIENDLY else "")
        for d in PLASMA_LOCAL_DIRS:
            self._path_item(root, HOME / ".local/share" / d, FRIENDLY.get(d, d),
                            private=d in PRIVATE_NAMES)

    def _scan_plasma_themes(self, root: Item) -> None:
        ls = HOME / ".local/share"
        groups = [
            ("Global themes", ls / "plasma/look-and-feel", "/usr/share/plasma/look-and-feel"),
            ("Plasma styles", ls / "plasma/desktoptheme", "/usr/share/plasma/desktoptheme"),
            ("Window decorations", ls / "aurorae/themes", "/usr/share/aurorae/themes"),
            ("Kvantum themes", ls / "Kvantum", "/usr/share/Kvantum"),
        ]
        for label, user_dir, sys_dir in groups:
            g = Item(id=f"group:themes:{label}", label=label)
            for d in _dirs(user_dir):
                self._path_item(g, d)
            for d in self._unowned(_dirs(Path(sys_dir))):
                self._path_item(g, d, note="installed by hand, system-wide")
            if g.children:
                root.add(g)
        cs = Item(id="group:themes:colors", label="Colour schemes")
        for f in _ls(ls / "color-schemes"):
            self._path_item(cs, f, f.stem)
        if cs.children:
            root.add(cs)
        self._path_item(root, HOME / ".config/Kvantum", "Kvantum settings")
        self._path_item(root, ls / "kstyle", "Widget styles")

    def _scan_icons(self, root: Item) -> None:
        for base in [HOME / ".local/share/icons", HOME / ".icons"]:
            for d in _dirs(base):
                if d.name == "default":
                    continue
                cursor = (d / "cursors").is_dir()
                self._path_item(root, d, note="cursor theme" if cursor else "")
        for d in self._unowned(_dirs(Path("/usr/share/icons"))):
            cursor = (d / "cursors").is_dir()
            self._path_item(root, d, note=("cursor theme, " if cursor else "") +
                            "installed by hand, system-wide")
        self._path_item(root, HOME / ".icons/default", "Default cursor (X11/GTK)")

    def _scan_fonts(self, root: Item) -> None:
        self._path_item(root, HOME / ".local/share/fonts", "Your fonts")
        self._path_item(root, HOME / ".fonts", "Your fonts (~/.fonts)")
        self._path_item(root, HOME / ".config/fontconfig", "Font settings")

    def _scan_sddm(self, root: Item) -> None:
        for d in self._unowned(_dirs(Path("/usr/share/sddm/themes"))):
            self._path_item(root, d, note="login theme")
        paths = [p for p in ["/etc/sddm.conf", "/etc/sddm.conf.d"] if os.path.exists(p)]
        if paths:
            self.claimed.update(paths)
            root.add(Item(id="covered:sddm-config", label="Login screen settings",
                          kind=COVERED, paths=paths))
        self._path_item(root, HOME / ".local/share/sddm", "Login screen user data")

    def _scan_widgets(self, root: Item) -> None:
        g = Item(id="group:widgets:plasmoids", label="Widgets")
        for d in _dirs(HOME / ".local/share/plasma/plasmoids"):
            name = d.name
            meta = d / "metadata.json"
            if meta.is_file():
                m = re.search(r'"Name"\s*:\s*"([^"]+)"', meta.read_text(errors="replace"))
                if m:
                    name = m.group(1)
            self._path_item(g, d, name, note=d.name if name != d.name else "")
        if g.children:
            root.add(g)
        for label, sub in [("KWin scripts", "scripts"), ("KWin effects", "effects")]:
            g = Item(id=f"group:widgets:{sub}", label=label)
            for d in _dirs(HOME / ".local/share/kwin" / sub):
                self._path_item(g, d)
            if g.children:
                root.add(g)

    def _scan_gtk(self, root: Item) -> None:
        paths = [str(p) for p in [HOME / ".config/gtk-3.0", HOME / ".config/gtk-4.0",
                                  HOME / ".gtkrc-2.0"] if p.exists()]
        if paths:
            self.claimed.update(paths)
            root.add(Item(id="covered:gtk-settings", label="GTK settings", kind=COVERED,
                          paths=paths))
        for base in [HOME / ".local/share/themes", HOME / ".themes"]:
            for d in _dirs(base):
                self._path_item(root, d, note="GTK theme")

    def _scan_wallpapers(self, root: Item) -> None:
        if self.mode == "themepack":
            rc = HOME / ".config/plasma-org.kde.plasma.desktop-appletsrc"
            seen = set()
            try:
                for line in rc.read_text(errors="replace").splitlines():
                    if line.startswith("Image="):
                        p = line.split("=", 1)[1].replace("file://", "")
                        if p not in seen and os.path.isfile(p):
                            seen.add(p)
                            self._path_item(root, p, note="in use")
            except OSError:
                pass
        else:
            pics = HOME / "Pictures"
            loose = [str(p) for p in _ls(pics) if p.is_file() and IMAGE_RE.search(p.name)]
            for d in _dirs(pics):
                self._path_item(root, d, f"Pictures/{d.name}", note="images only")
            if loose:
                root.add(Item(id="covered:pictures-loose", label="Images directly in Pictures",
                              kind=COVERED, paths=loose, note=f"{len(loose)} files"))
        self._path_item(root, HOME / ".local/share/wallpapers", "Wallpaper collection")

    # ── Theme pack only ──────────────────────────────────────────────────────
    def _scan_spicetify(self, root: Item) -> None:
        sp = HOME / ".config/spicetify"
        self._path_item(root, sp / "Themes", "Spicetify themes")
        self._path_item(root, sp / "Extensions", "Spicetify extensions")

    def _scan_rice(self, root: Item) -> None:
        for name in RICE_CONFIG:
            self._path_item(root, HOME / ".config" / name, name)
        for name in ["quickshell", "caelestia"]:
            self._path_item(root, HOME / ".local/share" / name, f"{name} data")
        self._path_item(root, HOME / ".local/bin", "Your scripts (~/.local/bin)",
                        default=False, note="may contain personal scripts — check first")

    def _detect_tier3(self) -> None:
        for name, what in TIER3_MARKERS.items():
            if (HOME / ".config" / name).exists():
                self.warnings.append(
                    f"{what}. This part of your desktop comes from a project with its own "
                    "installer — its settings are carried, but the software must be "
                    "installed separately.")

    # ── Apps (migrate only) ──────────────────────────────────────────────────
    def _app_tokens(self, pkg: str, desktops: list[dict]) -> set[str]:
        toks = {_norm(pkg)}
        base = pkg
        for suf in appmap.PKG_SUFFIXES:
            if base.endswith(suf):
                base = base[: -len(suf)]
        toks.add(_norm(base))
        for d in desktops:
            stem = Path(d["file"]).stem
            toks.add(_norm(stem.split(".")[-1]))
            toks.add(_norm(stem))
            if d.get("exec"):
                toks.add(_norm(Path(d["exec"]).name))
            if d.get("wmclass"):
                toks.add(_norm(d["wmclass"]))
            if d.get("name"):
                toks.add(_norm(d["name"]))
        return {t for t in toks if len(t) >= 3}

    @staticmethod
    def _parse_desktop(path: str) -> dict:
        info = {"file": path}
        try:
            in_entry = False
            for line in Path(path).read_text(errors="replace").splitlines():
                if line.startswith("["):
                    in_entry = line.strip() == "[Desktop Entry]"
                    continue
                if not in_entry or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k == "Name":
                    info["name"] = v
                elif k == "Exec":
                    tok = v.split()
                    if tok and tok[0] == "env":
                        tok = [t for t in tok[1:] if "=" not in t]
                    info["exec"] = tok[0] if tok else ""
                elif k == "StartupWMClass":
                    info["wmclass"] = v
                elif k == "NoDisplay":
                    info["nodisplay"] = v.strip().lower() == "true"
                elif k == "Type":
                    info["type"] = v
        except OSError:
            pass
        return info

    def _app_dirs(self, pkg: str, tokens: set[str],
                  candidates: dict[str, list[Path]]) -> list[str]:
        found: list[str] = []
        hint_key = appmap.PACKAGE_ALIASES.get(pkg, pkg)
        for h in appmap.APP_HINTS.get(hint_key, []):
            p = _h(h)
            if os.path.lexists(p) and p not in self.claimed:
                found.append(p)
        for where, entries in candidates.items():
            for e in entries:
                sp = str(e)
                if sp in self.claimed or sp in found:
                    continue
                n = _norm(e.name)
                if n in tokens or (where == "config" and n.endswith("rc") and n[:-2] in tokens):
                    found.append(sp)
        return found

    def _add_app_dirs(self, app: Item, dirs: list[str]) -> None:
        for d in dirs:
            is_cache = d.startswith(str(HOME / ".cache"))
            label = "Cache" if is_cache else ("Settings" if "/.config/" in d else "Data")
            self._extra_folder(app, d, label, default=not is_cache, note=_short(d))

    def _scan_apps(self, root: Item) -> None:
        explicit = sysinfo.pacman_list("e")
        foreign = set(sysinfo.pacman_list("m"))
        explicit_set = set(explicit)

        desktops_by_pkg: dict[str, list[dict]] = {}
        for f in Path("/usr/share/applications").glob("*.desktop"):
            owner = self.owners.get(str(f))
            if not owner:
                continue
            d = self._parse_desktop(str(f))
            if d.get("nodisplay") or d.get("type", "Application") != "Application":
                continue
            desktops_by_pkg.setdefault(owner, []).append(d)

        # Folders an app could own
        skip_cfg = set(PLASMA_CONFIG_FILES) | set(PLASMA_CONFIG_DIRS) | appmap.SKIP_CONFIG | {
            "Kvantum", "gtk-3.0", "gtk-4.0", "fontconfig", "systemd", "environment.d",
            "user-dirs.dirs", "user-dirs.locale", "spicetify"}
        candidates = {
            "config": [p for p in _ls(HOME / ".config") if p.name not in skip_cfg],
            "share": [p for p in _ls(HOME / ".local/share")
                      if p.name not in appmap.SKIP_LOCAL_SHARE],
            "cache": _ls(HOME / ".cache"),
        }
        browser_dirs = {_h(b) for b in appmap.BROWSER_DIRS}
        self.claimed.update(browser_dirs)

        apps_group = Item(id="group:apps:gui", label="Apps")
        app_pkgs = sorted((p for p in desktops_by_pkg if p in explicit_set
                           and p not in appmap.BROWSER_PACKAGES),
                          key=lambda p: desktops_by_pkg[p][0].get("name", p).lower())
        for i, pkg in enumerate(app_pkgs):
            if i % 10 == 0:
                self.progress(f"Matching apps… {pkg}", 45 + int(15 * i / max(1, len(app_pkgs))))
            ds = desktops_by_pkg[pkg]
            name = ds[0].get("name") or pkg
            app = apps_group.add(Item(id=f"group:app:{pkg}", label=name, note=pkg))
            src = "AUR" if pkg in foreign else "repo"
            app.add(Item(id=f"pkg:{pkg}", label=f"Package ({src})", kind=PACKAGE,
                         packages=[pkg], note=pkg))
            self._add_app_dirs(app, self._app_dirs(pkg, self._app_tokens(pkg, ds), candidates))
        if apps_group.children:
            root.add(apps_group)

        fp = sysinfo.flatpak_apps()
        if fp:
            g = Item(id="group:apps:flatpak", label="Flatpak apps")
            for app_id, name in fp:
                app = g.add(Item(id=f"group:flatpak:{app_id}", label=name, note=app_id))
                app.add(Item(id=f"flatpak:{app_id}", label="Flatpak app", kind=FLATPAK,
                             packages=[app_id], note=app_id))
                var = HOME / ".var/app" / app_id
                if var.exists():
                    self.claimed.add(str(var))
                    app.add(Item(id=f"extra:{var}", label="Data", kind=EXTRA,
                                 paths=[str(var)], note=_short(var)))
                    if (var / "cache").exists():
                        app.add(Item(id=f"extra:{var}/cache", label="Cache", kind=EXTRA,
                                     paths=[str(var / "cache")], default=False))
            root.add(g)

        others = [p for p in explicit if p not in desktops_by_pkg
                  and p not in appmap.BROWSER_PACKAGES]
        if others:
            g = Item(id="group:apps:other-pkgs", label="Other packages",
                     note="libraries, drivers, command-line tools")
            for p in others:
                g.add(Item(id=f"pkg:{p}", label=p, kind=PACKAGE, packages=[p],
                           note="AUR" if p in foreign else ""))
            root.add(g)

    def _scan_dotfiles(self, root: Item) -> None:
        for f in DOTFILES:
            self._path_item(root, HOME / f, f)
        self._path_item(root, HOME / ".local/bin", "Your scripts (~/.local/bin)")
        self._path_item(root, HOME / ".local/share/mime", "Custom file types")

    def _scan_browsers(self, root: Item) -> None:
        installed = set(sysinfo.pacman_list(""))
        browsers = [
            ("Brave", HOME / ".config/BraveSoftware/Brave-Browser", ["brave-bin", "brave"]),
            ("Zen Browser", HOME / ".zen", ["zen-browser-bin", "zen-browser"]),
            ("Firefox", HOME / ".mozilla/firefox", ["firefox"]),
        ]
        for label, d, pkgs in browsers:
            pkg = next((p for p in pkgs if p in installed), None)
            if not d.exists() and not pkg:
                continue
            b = Item(id=f"group:browser:{label}", label=label)
            if pkg:
                b.add(Item(id=f"pkg:{pkg}", label="Package", kind=PACKAGE, packages=[pkg],
                           note=pkg))
            if d.exists():
                profiles = [p for p in _dirs(d)
                            if p.name == "Default" or p.name.startswith("Profile ")
                            or (d.name != "Brave-Browser" and (p / "prefs.js").exists())]
                prof = Item(id=f"group:browser:{label}:profiles", label="Profiles",
                            note="bookmarks, history, extensions — saved passwords excluded")
                for p in profiles:
                    self._path_item(prof, p, p.name, private=True)
                if prof.children:
                    b.add(prof)
                else:
                    self._path_item(b, d, "Profile data", private=True)
            root.add(b)

    def _scan_private(self, root: Item) -> None:
        nm = "/etc/NetworkManager/system-connections"
        if os.path.isdir(nm):
            root.add(Item(id=f"covered:{nm}", label="WiFi & VPN passwords", kind=COVERED,
                          paths=[nm], private=True, note="needs your password to read"))
        self._path_item(root, HOME / ".ssh", "SSH keys", private=True)
        if (HOME / ".gnupg").exists():
            root.add(Item(id="virtual:@gpg", label="GPG keys", kind=VIRTUAL, paths=["@gpg"],
                          private=True))

    def _scan_system(self, root: Item) -> None:
        pac = [p for p in ["/etc/pacman.conf", "/etc/pacman.d/hooks"] if os.path.exists(p)]
        if pac:
            root.add(Item(id="covered:pacman-config", label="pacman settings & hooks",
                          kind=COVERED, paths=pac))
        self._path_item(root, HOME / ".config/systemd", "Your background services")
        self._path_item(root, HOME / ".config/environment.d", "Environment variables")
        self._path_item(root, HOME / ".config/user-dirs.dirs", "Folder locations")
        root.add(Item(id="virtual:@crontab", label="Scheduled jobs (crontab)",
                      kind=VIRTUAL, paths=["@crontab"]))
        power = [p for p in ["/etc/tlp.conf", "/etc/auto-cpufreq.conf"] if os.path.exists(p)]
        if power:
            root.add(Item(id="covered:power", label="Power settings", kind=COVERED,
                          paths=power))

    def _scan_leftovers(self, root: Item) -> None:
        """Everything in your home folder that no other section claimed."""
        skip_cfg = set(PLASMA_CONFIG_FILES) | set(PLASMA_CONFIG_DIRS) | appmap.SKIP_CONFIG
        skip_share = set(PLASMA_LOCAL_DIRS) | appmap.SKIP_LOCAL_SHARE | {
            "plasma", "color-schemes", "aurorae", "kwin", "kstyle", "Kvantum", "icons",
            "fonts", "themes", "wallpapers", "sddm", "mime", "applications"}

        def unclaimed(base: Path, skip: set[str]) -> list[Path]:
            return [p for p in _ls(base) if p.name not in skip and str(p) not in self.claimed]

        g = Item(id="group:other:config", label="Other settings folders",
                 note="~/.config entries not matched to an app")
        for p in unclaimed(HOME / ".config", skip_cfg):
            self._extra_folder(g, p)
        if g.children:
            root.add(g)

        g = Item(id="group:other:share", label="Other app data",
                 note="~/.local/share entries not matched to an app")
        for p in unclaimed(HOME / ".local/share", skip_share):
            self._extra_folder(g, p)
        if g.children:
            root.add(g)

        g = Item(id="group:other:dot", label="Other hidden folders in home")
        for p in _ls(HOME):
            if not p.name.startswith(".") or p.name in HANDLED_DOTDIRS:
                continue
            if str(p) in self.claimed or not p.is_dir():
                continue
            redl = p.name in REDOWNLOADABLE_DOTDIRS
            self._path_item(g, p, kind=EXTRA, default=not redl,
                            note="re-downloadable" if redl else "")
        if g.children:
            root.add(g)

        g = Item(id="group:other:cache", label="Other caches",
                 note="rebuild themselves — usually not worth moving")
        for p in unclaimed(HOME / ".cache", set()):
            self._path_item(g, p, kind=EXTRA, default=False)
        if g.children:
            root.add(g)

    # ── sizes ────────────────────────────────────────────────────────────────
    def _fill_sizes(self, roots: list[Item]) -> None:
        leaves = [l for r in roots for l in r.leaves() if l.paths]
        all_paths = [p for l in leaves for p in l.paths]
        sizes = sysinfo.du_bytes(all_paths)
        leaf_paths = {p for l in leaves for p in l.paths}
        for l in leaves:
            total = 0
            for p in l.paths:
                own = sizes.get(p, 0)
                # Nested items (e.g. Steam/steamapps inside Steam) are their own
                # leaf — subtract them so nothing is counted twice.
                for other in leaf_paths:
                    if other != p and other.startswith(p + "/"):
                        own -= sizes.get(other, 0)
                total += max(own, 0)
            l.size = total
            # Big non-cache folders start unticked so a stray VM image or
            # game library doesn't silently fill the backup drive.
            if l.kind == EXTRA and l.default and l.size > BIG:
                l.default = False
                l.note = (l.note + " · " if l.note else "") + "very large — ticked off"
            if (l.kind == EXTRA and l.default and l.size > MEDIUM
                    and "re-downloadable" in l.note):
                l.default = False
