"""Small wrappers around system commands. Every call degrades to an empty
result when the tool is missing, so the app still opens on a broken system."""

from __future__ import annotations

import os
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ENV_C = {**os.environ, "LC_ALL": "C"}


def run(cmd: list[str], timeout: int = 120) -> str:
    if not shutil.which(cmd[0]):
        return ""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           env=ENV_C, errors="replace")
        return r.stdout
    except (subprocess.SubprocessError, OSError):
        return ""


def pacman_list(flag: str) -> list[str]:
    """pacman -Qq<flag> → package names. '' = all, 'e' = explicit, 'm' = foreign/AUR."""
    return [l for l in run(["pacman", f"-Qq{flag}"]).splitlines() if l]


def pacman_owners(paths: list[str]) -> dict[str, str]:
    """Map each path to the package that owns it. Unowned paths are absent."""
    out: dict[str, str] = {}
    if not paths or not shutil.which("pacman"):
        return out
    for i in range(0, len(paths), 200):
        chunk = paths[i:i + 200]
        text = run(["pacman", "-Qo", "--", *chunk], timeout=300)
        for line in text.splitlines():
            # "/usr/share/x/ is owned by pkg 1.2-3"
            if " is owned by " in line:
                p, rest = line.split(" is owned by ", 1)
                out[p.rstrip("/")] = rest.split()[0]
    return out


def pacman_exists(pkg: str) -> bool:
    return bool(run(["pacman", "-Si", pkg], timeout=30))


def flatpak_apps() -> list[tuple[str, str]]:
    text = run(["flatpak", "list", "--app", "--columns=application,name"])
    apps = []
    for line in text.splitlines():
        parts = line.split("\t")
        if parts and parts[0] and parts[0] != "Application ID":
            apps.append((parts[0], parts[1] if len(parts) > 1 else parts[0]))
    return apps


def du_bytes(paths: list[str], workers: int = 8) -> dict[str, int]:
    """Apparent size (what actually gets copied) for each path, in parallel."""
    paths = [p for p in dict.fromkeys(paths) if p and not p.startswith("@")]

    def one(p: str) -> tuple[str, int]:
        try:
            if os.path.isfile(p) or os.path.islink(p):
                return p, os.lstat(p).st_size
            if not os.path.isdir(p):
                return p, 0
        except OSError:
            return p, 0
        text = run(["du", "-sbx", "--", p], timeout=900)
        try:
            return p, int(text.split()[0])
        except (IndexError, ValueError):
            return p, 0

    with ThreadPoolExecutor(max_workers=workers) as ex:
        return dict(ex.map(one, paths))


def free_bytes(path: str) -> int:
    p = Path(path)
    while not p.exists() and p != p.parent:
        p = p.parent
    try:
        return shutil.disk_usage(p).free
    except OSError:
        return 0


def plasma_version() -> str:
    text = run(["plasmashell", "--version"], timeout=20)
    parts = text.split()
    return parts[1] if len(parts) > 1 else ""


def read_ini_value(path: Path, key: str, section: str | None = None) -> str:
    try:
        cur = None
        for raw in path.read_text(errors="replace").splitlines():
            line = raw.strip()
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1]
                continue
            if section is not None and cur != section:
                continue
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return ""
