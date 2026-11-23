"""Entry point: ``python -m hermitcrab`` or the ``hermitcrab`` launcher."""

from __future__ import annotations

import argparse
import sys

from . import APP_NAME, __version__


def main() -> int:
    ap = argparse.ArgumentParser(prog="hermitcrab",
                                 description=f"{APP_NAME} — move your whole desktop to a new shell")
    ap.add_argument("--version", action="version", version=f"{APP_NAME} {__version__}")
    ap.add_argument("--askpass", nargs=argparse.REMAINDER,
                    help=argparse.SUPPRESS)  # used internally as SUDO_ASKPASS
    ap.add_argument("--install-desktop", action="store_true",
                    help="add HermitCrab to the application menu (AppImage)")
    ap.add_argument("--uninstall-desktop", action="store_true",
                    help="remove HermitCrab from the application menu")
    ap.add_argument("--self-test", action="store_true",
                    help="check the bundle and run a scan without opening a window")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if args.askpass is not None:
        from .askpass import main as askpass_main
        return askpass_main(args.askpass)

    if args.install_desktop or args.uninstall_desktop:
        from .ui import desktop
        msg = desktop.install() if args.install_desktop else desktop.uninstall()
        print(msg)
        return 0

    from .ui.window import run
    return run()


def self_test() -> int:
    """Used by CI and for bug reports: prove the bundle is complete."""
    import os
    from pathlib import Path

    ok = True
    print(f"{APP_NAME} {__version__}  (frozen={getattr(sys, 'frozen', False)})")
    from . import job
    try:
        sd = job.scripts_dir()
        missing = [s for s in ("kde-lib.sh", "kde-migrate.sh", "kde-themepack.sh",
                               "kde-restore.sh") if not (sd / s).is_file()]
        print(f"scripts : {sd}  {'OK' if not missing else 'MISSING ' + ', '.join(missing)}")
        ok &= not missing
    except FileNotFoundError as e:
        print(f"scripts : {e}")
        ok = False
    from .ui import desktop
    icon = desktop.icon_path()
    print(f"icon    : {icon or 'MISSING'}")
    ok &= icon is not None
    import PySide6
    from PySide6.QtCore import QLibraryInfo
    plug = Path(QLibraryInfo.path(QLibraryInfo.LibraryPath.PluginsPath))
    plats = sorted(p.name for p in (plug / "platforms").glob("*.so")) if plug.exists() else []
    print(f"qt      : PySide6 {PySide6.__version__}, platforms: {', '.join(plats) or 'NONE'}")
    if not any(p.startswith("libqwayland") for p in plats) or "libqxcb.so" not in plats:
        print("          WARNING: wayland or xcb platform plugin missing")
        ok = False
    from .scanner import Scanner
    res = Scanner("themepack").run()
    n = sum(1 for r in res.roots for _ in r.leaves())
    print(f"scan    : theme pack scan OK — {len(res.roots)} sections, {n} items")
    print("RESULT  :", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
