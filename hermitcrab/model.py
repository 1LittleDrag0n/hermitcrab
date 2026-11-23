"""Data model shared by the scanners and the GUI.

Everything the app can move is an ``Item`` in a tree. Leaves carry the real
payload (paths or package names); groups just hold children. How an unticked
or ticked leaf is translated for the backend scripts depends on its ``kind``:

    covered   the script copies this path itself      untick -> exclude path
    extra     the script only copies it if asked      tick   -> include path
    package   pacman / AUR package                    untick -> exclude package
    flatpak   Flatpak app id                          untick -> exclude package
    virtual   non-path thing (@gpg, @crontab)         untick -> exclude token
    pack      a path inside a pack being restored     untick -> pruned before restore
    group     container only
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator

COVERED = "covered"
EXTRA = "extra"
PACKAGE = "package"
FLATPAK = "flatpak"
VIRTUAL = "virtual"
PACK = "pack"
GROUP = "group"


@dataclass
class Item:
    id: str
    label: str
    kind: str = GROUP
    paths: list[str] = field(default_factory=list)
    packages: list[str] = field(default_factory=list)
    size: int = 0                 # bytes this item adds on its own
    default: bool = True          # ticked when first shown
    private: bool = False         # passwords, keys, history — shown with a lock
    note: str = ""                # short hint shown in the tree
    children: list["Item"] = field(default_factory=list)

    def add(self, child: "Item") -> "Item":
        self.children.append(child)
        return child

    def walk(self) -> Iterator["Item"]:
        yield self
        for c in self.children:
            yield from c.walk()

    def leaves(self) -> Iterator["Item"]:
        if not self.children:
            yield self
        else:
            for c in self.children:
                yield from c.leaves()

    @property
    def location(self) -> str:
        if self.paths:
            return self.paths[0]
        if self.packages:
            return ", ".join(self.packages[:3]) + ("…" if len(self.packages) > 3 else "")
        return ""


@dataclass
class ScanResult:
    mode: str                     # migrate | themepack | restore
    roots: list[Item]
    warnings: list[str] = field(default_factory=list)
    info: dict = field(default_factory=dict)

    def all_items(self) -> Iterator[Item]:
        for r in self.roots:
            yield from r.walk()


def human_size(n: int) -> str:
    try:
        f = float(n)
    except (TypeError, ValueError):
        return ""
    if f <= 0:
        return ""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if f < 1024 or unit == "TB":
            return f"{f:.0f} {unit}" if unit in ("B", "KB") else f"{f:.1f} {unit}"
        f /= 1024
    return ""