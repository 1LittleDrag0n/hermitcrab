"""Turn the ticked/unticked tree into a run of one of the backend scripts.

Backup modes pass the selection as files the scripts read (KP_* variables).
Restore works on a hard-linked working copy of the pack: unticked items are
deleted from the copy, which leaves the original pack untouched.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from .model import COVERED, EXTRA, FLATPAK, PACK, PACKAGE, VIRTUAL, Item, ScanResult


def scripts_dir() -> Path:
    env = os.environ.get("HERMITCRAB_SCRIPTS")
    if env and Path(env).is_dir():
        return Path(env)
    here = Path(__file__).resolve().parent
    bundle = Path(getattr(sys, "_MEIPASS", here))      # PyInstaller (AppImage)
    for cand in [bundle / "scripts", here / "scripts", here.parent / "scripts",
                 Path("/usr/share/hermitcrab/scripts"),
                 Path.home() / ".local/share/hermitcrab/scripts"]:
        if (cand / "kde-lib.sh").is_file():
            return cand
    raise FileNotFoundError("Backend scripts (kde-lib.sh) not found")


@dataclass
class Selection:
    includes: list[str] = field(default_factory=list)
    excludes: list[str] = field(default_factory=list)
    exclude_pkgs: list[str] = field(default_factory=list)
    pack_prune: list[str] = field(default_factory=list)
    ticked_bytes: int = 0
    ticked_count: int = 0


def _under(p: str, roots: list[str]) -> bool:
    return any(p == r or p.startswith(r.rstrip("/") + "/") for r in roots)


def compute_selection(result: ScanResult, checked: dict[str, bool]) -> Selection:
    sel = Selection()
    leaves = [l for r in result.roots for l in r.leaves()]
    is_on = lambda it: checked.get(it.id, it.default)

    ticked_extra = sorted({p for l in leaves if l.kind == EXTRA and is_on(l) for p in l.paths},
                          key=len)
    for p in ticked_extra:
        if not _under(p, sel.includes):
            sel.includes.append(p)

    for l in leaves:
        on = is_on(l)
        if on:
            sel.ticked_bytes += l.size
            sel.ticked_count += 1
        if l.kind in (COVERED, VIRTUAL) and not on:
            sel.excludes += l.paths
        elif l.kind == EXTRA and not on:
            # Only needed when a parent folder is being included
            sel.excludes += [p for p in l.paths if _under(p, sel.includes)]
        elif l.kind in (PACKAGE, FLATPAK) and not on:
            sel.exclude_pkgs += l.packages
        elif l.kind == PACK and not on:
            sel.pack_prune += l.paths
    sel.excludes = sorted(set(sel.excludes))
    sel.exclude_pkgs = sorted(set(sel.exclude_pkgs))
    return sel


# ── answers for restore prompts ──────────────────────────────────────────────
SECTION_PROMPTS = [
    (r"Restore Plasma appearance config", ["config", "kde-config"]),
    (r"Restore themes", ["themes"]),
    (r"Restore icons and cursors", ["icons"]),
    (r"Restore fonts", ["fonts"]),
    (r"Restore SDDM login theme", ["sddm"]),
    (r"Restore widgets and KWin effects", ["widgets"]),
    (r"Restore extra customization|Restore these\?", ["extras"]),
    (r"Restore GTK", ["gtk"]),
    (r"Restore wallpapers", ["wallpapers"]),
    (r"Restore Spicetify", ["spicetify"]),
    (r"Restore app configs and shell dotfiles", ["apps/config", "apps/home", "apps/local"]),
    (r"Restore app data", ["apps/extra"]),
    (r"Restore browser profiles", ["browsers"]),
    (r"Restore WiFi/VPN", ["network/nm-connections"]),
    (r"Restore power config", ["network/tlp.conf", "network/auto-cpufreq.conf"]),
    (r"Restore SSH keys", ["keys/ssh"]),
    (r"Import GPG keys", ["keys/gpg-private.asc"]),
    (r"Restore systemd user units and crontab", ["misc"]),
]


def restore_answers(result: ScanResult, checked: dict[str, bool], pack: Path,
                    switch_sddm: bool, ignore_mismatch: bool) -> list[tuple[str, str]]:
    leaves = [l for r in result.roots for l in r.leaves()]
    on = lambda it: checked.get(it.id, it.default)
    ticked_rel = [os.path.relpath(p, pack) for l in leaves
                  if l.kind == PACK and on(l) for p in l.paths]
    any_pkg = any(l.kind == PACKAGE and on(l) for l in leaves)
    any_flat = any(l.kind == FLATPAK and on(l) for l in leaves)

    yn = lambda b: "y" if b else "n"
    ans: list[tuple[str, str]] = []
    for pat, prefixes in SECTION_PROMPTS:
        hit = any(r == p or r.startswith(p + "/") for r in ticked_rel for p in prefixes)
        ans.append((pat, yn(hit)))
    ans += [
        (r"Plasma major version|Continue anyway", yn(ignore_mismatch)),
        (r"Run a full system update now|Run sudo pacman -Syu now", yn(any_pkg or any_flat)),
        (r"Install these .* packages", "y"),
        (r"Install Flatpak apps", yn(any_flat)),
        (r"Install 'yay' now", "y"),
        (r"Install SDDM and switch|Switch the login manager to SDDM", yn(switch_sddm)),
        (r"Install them now|Install layer-shell|from AUR\?", "y"),
        (r"Enable and start", "y"),
        (r"Understood, continue|^Continue\?$", "y"),
        (r"Apply global theme", "y"),
    ]
    return ans


@dataclass
class Job:
    title: str
    program: list[str]
    env: dict[str, str]
    runtime_dir: Path
    output_hint: str = ""          # where results land (for the "Open folder" button)
    cleanup: list[Path] = field(default_factory=list)
    summary: list[str] = field(default_factory=list)


def _write(path: Path, lines: list[str]) -> str:
    path.write_text("".join(l + "\n" for l in lines))
    return str(path)


def make_askpass(runtime: Path) -> str:
    """A tiny wrapper sudo calls for the password (shows our Qt dialog)."""
    sh = runtime / "askpass.sh"
    if getattr(sys, "frozen", False):          # AppImage: the binary itself
        line = f'exec "{sys.executable}" --askpass "$@"\n'
    else:
        pkg_parent = Path(__file__).resolve().parent.parent
        line = (f'PYTHONPATH="{pkg_parent}${{PYTHONPATH:+:$PYTHONPATH}}" '
                f'exec "{sys.executable}" -m hermitcrab --askpass "$@"\n')
    sh.write_text("#!/bin/sh\n" + line)
    sh.chmod(0o700)
    return str(sh)


def _base_env(runtime: Path) -> dict[str, str]:
    env = dict(os.environ)
    env.update({
        "KP_GUI": "1",
        "KP_NONINTERACTIVE": "1",
        "SUDO_ASKPASS": make_askpass(runtime),
        "TERM": "dumb",
    })
    return env


class WrongPassword(RuntimeError):
    """The archive is encrypted and the password didn't open it."""


def is_encrypted(path: str) -> bool:
    return str(path).endswith(".gpg")


def write_secret(password: str) -> Path:
    """Put a password in a private file in RAM (XDG_RUNTIME_DIR is a per-user
    tmpfs, mode 700). Mode 600, created exclusively. The caller deletes it.
    Never passed on a command line, where other programs can read it."""
    base = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    d = Path(tempfile.mkdtemp(prefix="hermitcrab-secret-", dir=base))
    d.chmod(0o700)
    f = d / "pass"
    fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(password + "\n")
    return d


def build_backup_job(result: ScanResult, checked: dict[str, bool], dest: str,
                     password: str | None = None, delete_folder: bool = False) -> Job:
    runtime = Path(tempfile.mkdtemp(prefix="hermitcrab-"))
    sel = compute_selection(result, checked)
    env = _base_env(runtime)
    env["KP_EXCLUDE_FILE"] = _write(runtime / "exclude.txt", sel.excludes)
    env["KP_EXCLUDE_PKGS"] = _write(runtime / "exclude-pkgs.txt", sel.exclude_pkgs)
    env["KP_ANSWERS_FILE"] = _write(runtime / "answers.tsv",
                                    ["Continue building the pack anyway\ty"])
    script = "kde-migrate.sh" if result.mode == "migrate" else "kde-themepack.sh"
    if result.mode == "migrate":
        env["KP_INCLUDE_FILE"] = _write(runtime / "include.txt", sel.includes)
    args = [dest] if dest else []
    if result.mode == "themepack":
        args += ["--no-sweep"]
    cleanup = [runtime]
    summary = _summary(sel, result.mode)
    if result.mode == "migrate":
        if password:
            secret = write_secret(password)
            cleanup.append(secret)
            env["KP_ENCRYPT"] = "yes"
            env["KP_PASSPHRASE_FILE"] = str(secret / "pass")
            summary.append("password protected (AES-256)")
        if delete_folder:
            env["KP_DELETE_FOLDER"] = "yes"
            summary.append("folder deleted after the archive is verified")
        env["KP_ESTIMATE_BYTES"] = str(sel.ticked_bytes)
    prog = ["setsid", "-w", "bash", str(scripts_dir() / script), *args]
    title = "Full backup" if result.mode == "migrate" else "Theme pack"
    return Job(title=title, program=prog, env=env, runtime_dir=runtime,
               output_hint=dest or str(Path.home()), cleanup=cleanup,
               summary=summary)


def _summary(sel: Selection, mode: str) -> list[str]:
    s = [f"{sel.ticked_count} items selected"]
    if mode == "migrate":
        s.append(f"{len(sel.includes)} app folders added")
    if sel.excludes:
        s.append(f"{len(sel.excludes)} paths left out")
    if sel.exclude_pkgs:
        s.append(f"{len(sel.exclude_pkgs)} packages left out")
    if sel.pack_prune:
        s.append(f"{len(sel.pack_prune)} items left out of the restore")
    return s


# ── restore working copy ─────────────────────────────────────────────────────
def _decrypt_extract(src: Path, work: Path, password: str) -> None:
    """gpg → tar in one stream: the decrypted archive never touches the disk.
    The password goes to gpg through a pipe, not the command line."""
    if not shutil.which("gpg"):
        raise RuntimeError("gpg is not installed — it's needed to open "
                           "password-protected backups (sudo pacman -S gnupg)")
    # stderr goes to temp files so neither process can block on a full pipe
    with tempfile.TemporaryFile() as ge, tempfile.TemporaryFile() as te:
        gpg = subprocess.Popen(
            ["gpg", "--batch", "--quiet", "--no-symkey-cache", "--pinentry-mode", "loopback",
             "--passphrase-fd", "0", "--decrypt", str(src)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=ge)
        tar = subprocess.Popen(["tar", "-xzf", "-", "-C", str(work)],
                               stdin=gpg.stdout, stderr=te)
        gpg.stdout.close()                 # tar owns the read end now
        try:
            gpg.stdin.write((password + "\n").encode())
            gpg.stdin.close()
        except BrokenPipeError:
            pass
        g, t = gpg.wait(), tar.wait()
        ge.seek(0); te.seek(0)
        gpg_err = ge.read().decode(errors="replace")
        tar_err = te.read().decode(errors="replace")
    if g != 0:
        if re.search(r"bad (session key|passphrase)|decryption failed", gpg_err, re.I):
            raise WrongPassword("Wrong password")
        raise RuntimeError(f"Could not decrypt: {gpg_err.strip()[-300:]}")
    if t != 0:
        raise RuntimeError(f"Could not extract: {tar_err.strip()[:300]}")


def prepare_pack(source: str, progress=lambda m: None,
                 password: str | None = None) -> tuple[Path, Path]:
    """Make a private working copy of a pack. Returns (pack_dir, work_root).

    Archives are extracted next to themselves. Folders are copied with hard
    links (instant, no extra space) so pruning never touches the original.
    Encrypted archives (.gpg) need `password`; a wrong one raises WrongPassword.
    """
    src = Path(source).expanduser().resolve()
    parent = src.parent
    try:
        work = Path(tempfile.mkdtemp(prefix=".hermitcrab-work-", dir=parent))
    except OSError:
        work = Path(tempfile.mkdtemp(prefix="hermitcrab-work-"))
    work.chmod(0o700)
    if src.is_file() and is_encrypted(str(src)):
        if not password:
            shutil.rmtree(work, ignore_errors=True)
            raise WrongPassword("This backup is password protected")
        progress("Unlocking and extracting the archive…")
        try:
            _decrypt_extract(src, work, password)
        except Exception:
            shutil.rmtree(work, ignore_errors=True)
            raise
    elif src.is_file():
        progress("Extracting the archive…")
        r = subprocess.run(["tar", "-xzf", str(src), "-C", str(work)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            shutil.rmtree(work, ignore_errors=True)
            raise RuntimeError(f"Could not extract: {r.stderr.strip()[:300]}")
    if src.is_file():
        subs = [p for p in work.iterdir() if p.is_dir()]
        if len(subs) != 1:
            shutil.rmtree(work, ignore_errors=True)
            raise RuntimeError("This archive doesn't look like a HermitCrab pack")
        return subs[0], work
    if not src.is_dir():
        raise RuntimeError(f"Not found: {src}")
    progress("Preparing a working copy…")
    dst = work / src.name
    r = subprocess.run(["cp", "-al", str(src), str(dst)], capture_output=True, text=True)
    if r.returncode != 0:
        shutil.rmtree(dst, ignore_errors=True)
        progress("Different drive — making a full copy (this can take a while)…")
        r = subprocess.run(["cp", "-a", str(src), str(dst)], capture_output=True, text=True)
        if r.returncode != 0:
            shutil.rmtree(work, ignore_errors=True)
            raise RuntimeError(f"Could not copy the pack: {r.stderr.strip()[:300]}")
    return dst, work


def _rewrite_list(f: Path, drop: set[str]) -> None:
    """Rewrite a package list WITHOUT touching a hard-linked original."""
    if not f.is_file():
        return
    keep = [l for l in f.read_text(errors="replace").splitlines() if l.strip() not in drop]
    tmp = f.with_suffix(f.suffix + ".hc-tmp")
    tmp.write_text("".join(l + "\n" for l in keep))
    os.replace(tmp, f)


def build_restore_job(result: ScanResult, checked: dict[str, bool], pack: Path,
                      work_root: Path, switch_sddm: bool, ignore_mismatch: bool) -> Job:
    runtime = Path(tempfile.mkdtemp(prefix="hermitcrab-"))
    sel = compute_selection(result, checked)

    for p in sel.pack_prune:
        pp = Path(p)
        if not str(pp.resolve()).startswith(str(pack.resolve())):
            continue          # never delete outside the working copy
        if pp.is_dir() and not pp.is_symlink():
            shutil.rmtree(pp, ignore_errors=True)
        elif pp.exists() or pp.is_symlink():
            pp.unlink()
    drop = set(sel.exclude_pkgs)
    for f in ["dependencies/native.txt", "dependencies/aur.txt", "packages/native.txt",
              "packages/aur.txt", "packages/flatpak.txt"]:
        _rewrite_list(pack / f, drop)

    env = _base_env(runtime)
    answers = restore_answers(result, checked, pack, switch_sddm, ignore_mismatch)
    env["KP_ANSWERS_FILE"] = _write(runtime / "answers.tsv",
                                    [f"{pat}\t{a}" for pat, a in answers])
    prog = ["setsid", "-w", "bash", str(scripts_dir() / "kde-restore.sh"), str(pack)]
    return Job(title="Restore", program=prog, env=env, runtime_dir=runtime,
               output_hint=str(Path.home()), cleanup=[runtime, work_root],
               summary=_summary(sel, "restore"))


def dry_run_text(result: ScanResult, checked: dict[str, bool], extra: str = "",
                 base: Path | None = None) -> str:
    sel = compute_selection(result, checked)
    home = str(Path.home())
    sh = lambda p: "~" + p[len(home):] if p.startswith(home) else p
    out = [f"Mode: {result.mode}", f"Selected: {sel.ticked_count} items"]
    if extra:
        out.append(extra)
    if sel.includes:
        out += ["", "App folders that will be added:"] + [f"  + {sh(p)}" for p in sel.includes]
    if sel.excludes:
        out += ["", "Left out:"] + [f"  − {sh(p)}" for p in sel.excludes]
    if sel.pack_prune:
        out += ["", "Not restored:"] + [f"  − {os.path.relpath(p, base) if base else p}"
                                       for p in sel.pack_prune]
    if sel.exclude_pkgs:
        out += ["", "Packages left out:"] + [f"  − {p}" for p in sel.exclude_pkgs]
    out += ["", "Nothing has been copied or installed."]
    return "\n".join(out)
