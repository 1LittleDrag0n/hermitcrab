<div align="center">

<img src="hermitcrab/assets/hermitcrab.svg" width="110" alt="HermitCrab logo">

# HermitCrab

**Move your whole desktop into a new shell.**

A hermit crab carries its home into a new shell when it outgrows the old one.
HermitCrab does the same for your Linux desktop: back up your theme, widgets,
login screen, settings and every app you have installed — then rebuild all of it
on a fresh install, a second PC, or a friend's machine.

</div>

---

> ## ⚠️ Read this first
>
> **This is a work in progress.** It is tested on CachyOS with KDE Plasma 6.7 and a heavily customised setup, and not much else. Expect rough edges, and please open an issue when something is missed.
>
> **A restore can break your system.** It installs packages, writes to `/usr`, `/etc/sddm.conf.d` and your whole `~/.config`, and can switch your login manager. An earlier version produced a machine that booted to a black screen. That was fixed, but there will be other cases.
>
> **Before restoring:**
>
> 1. **Take a snapshot.** On btrfs with snapper: `sudo snapper -c root create --description "before restore"`. Otherwise back up `~/.config` and `~/.local/share` at minimum.
> 2. **Know how to reach a text console:** Ctrl+Alt+F3. Without one you have no way back.
> 3. **Try it on a spare machine or VM first** if the system matters to you.
>
> Recovery steps are in [Safety](#safety). No warranty — see the licence.

---

## What it does

HermitCrab has three modes. Every mode **scans first and shows you everything** before anything is copied, so you can untick what you don't want.

| | **Full backup** | **Theme pack** | **Restore** |
|---|---|---|---|
| For | Your own machines | Sharing your look with friends | Opening either kind of pack |
| Theme, icons, cursors, fonts | ✅ | ✅ | choose what to bring back |
| Panels, widgets, KWin effects | ✅ | ✅ | |
| Login screen (SDDM) | ✅ | ✅ | |
| **Every installed app** + its settings, data, cache | ✅ | ❌ | |
| Browser profiles, bookmarks | ✅ | ❌ | |
| WiFi / VPN passwords, SSH / GPG keys | ✅ 🔒 | **never** | |
| Safe to send to someone | **No — keep private** | Yes, checked before building | |

### The review screen

<!-- Add a screenshot here: docs/review.png -->

- **Every app is grouped with its own folders.** DaVinci Resolve shows its package, its settings, its data and its render cache as separate ticks — untick the whole app, or just the cache.
- **Caches start unticked.** They're usually huge and rebuild themselves.
- **Very large folders start unticked** (over 10 GB) — a Steam game library or a VM image never fills your backup drive by accident. Steam's `steamapps` and similar are split out as their own item so the rest of the app still moves.
- **Private items are marked 🔒** and never appear at all in a theme pack.
- **Search** to jump straight to an item (`davinci`, `cursor`, `steam`).
- **Sizes update as you tick**, with the free space at your destination.
- **Dry run** shows exactly what would happen without touching anything.
- **Presets** save a selection — e.g. "laptop" vs "desktop" — to reuse later.
- **Password protection** (full backup only) — lock the archive like a password-protected zip. See [Password-protected backups](#password-protected-backups).

---

## Download & run (AppImage)

1. Download `HermitCrab-x.y.z-x86_64.AppImage` from the [Releases](../../releases) page.
2. Make it executable and run it:
   ```bash
   chmod +x HermitCrab-*.AppImage
   ./HermitCrab-*.AppImage
   ```
3. To put it in your application menu: **HermitCrab menu → Add to application menu**.
   It copies itself to `~/.local/share/hermitcrab/`, so the launcher keeps working even if you delete the download.

**If it doesn't start**, your system may be missing FUSE 2, which AppImages need:

```bash
sudo pacman -S fuse2
```

Or skip FUSE entirely:

```bash
./HermitCrab-*.AppImage --appimage-extract-and-run
```

The AppImage carries its own Qt, so it can't load your system's Breeze/Kvantum style. It reads your KDE colours, font and icon theme instead, so it still matches your desktop closely. For the exact native look, install from source.

## Install from source

Uses your distro's PySide6, so the window follows your real KDE theme.

```bash
git clone https://github.com/YOURNAME/hermitcrab
cd hermitcrab
./install.sh
```

This installs `pyside6` and `rsync` from the official Arch repos if they're missing, then adds HermitCrab to your application menu. Remove it with `./uninstall.sh` (`--purge` also deletes saved presets).

---

## How to use it

### Back up (or make a theme pack)

1. Open HermitCrab and pick **Full backup** or **Theme pack**.
2. Choose where to save it — another drive is best. Click **Scan**.
3. Look through the list. Untick anything you don't want. Use **Dry run** if you want to double-check.
4. *(Full backup, optional)* Tick **Protect the backup with a password** and type it twice. **Delete the backup folder once the archive is made** ticks itself, so you end up with one locked file.
5. Click **Start**. A password prompt appears for steps that read system files (WiFi passwords, the login theme) — that's your system password, not the backup password.
6. You get a folder and a `.tar.gz` — or a single `.tar.gz.gpg` if you set a password and chose to delete the folder. **A full backup is private** — it holds passwords and keys. A theme pack can be sent to anyone.

### Password-protected backups

A full backup holds your WiFi passwords, SSH keys and browser data, so locking it is a good idea if it lives on a USB drive or in the cloud.

- **It works like a password-protected zip.** The archive is encrypted with AES-256 (using `gpg`, already installed on most systems), and nobody can open it without the password.
- **There is no reset.** If you forget the password, the backup is gone for good. Write it down somewhere safe.
- **No unlocked copy is left behind.** The archive is compressed and encrypted in one go, so an unlocked `.tar.gz` is never written to disk. If you choose to delete the folder, HermitCrab first reads the whole archive back to check it, and only deletes the folder if that check passes. If the check fails, the folder is kept.
- **The unlocked folder is built on your computer's own drive** when possible, so only the locked file is written to your backup drive (a deleted file can sometimes be recovered from a USB stick or SSD). If your computer's drive doesn't have room, it's built on the backup drive instead. A short log file (no passwords) is saved next to the archive.
- **Restoring:** pick the `.tar.gz.gpg` in **Restore** and HermitCrab asks for the password. A wrong password changes nothing; you can just try again.
- **Without HermitCrab**, on any Linux machine:
  ```bash
  gpg -d kde-migrate-DATE.tar.gz.gpg | tar -xz
  ```

### Restore

1. Take a snapshot (see [Safety](#safety)).
2. Open HermitCrab, pick **Restore**, choose the `.tar.gz` / `.tar.gz.gpg` (or an unpacked folder). Click **Scan**. A locked backup asks for its password first.
3. Untick anything you don't want back.
4. Leave **"Switch the login screen to SDDM"** off unless the pack has a custom login theme you want and you know how to reach a text console.
5. Click **Start**, then log out and back in — a reboot is safest.

Your pack is never modified. HermitCrab works on a private copy (hard links when the pack is a folder, so it's instant and takes no extra space) and deletes the copy afterwards.

---

## Why it's more than a tarball

Most backup scripts copy a list of config files and extract them on the other side. That gets you about half a desktop: the settings arrive, but the themes they point at aren't installed, the widgets aren't there, the login screen falls back to default, and effects are switched on with no plugins behind them.

HermitCrab treats a desktop as **files + packages + settings applied in the right order**.

**It reinstalls your software.** Native, AUR and Flatpak packages are captured separately and installed before any settings are written. It never runs `pacman -Sy` and then installs specific packages — that's a partial upgrade and on Arch it leaves a system that can't reach a desktop. It does a full `-Syu`, or installs nothing.

**It works out what a theme actually needs.** Your login theme's QML is read, its `import` lines mapped to packages, and Qt5 vs Qt6 detected *per theme* — a Qt5 login theme on a Qt6 desktop is normal, and loading it with the wrong greeter gives a black screen with nothing in the journal. It also adds the three things no import scanner can see:

| Missing piece | What you get without it |
|---|---|
| `qt5-wayland` / `qt6-wayland` | Login screen crashes before drawing anything |
| `layer-shell-qt5` | Login screen runs but shows nothing — mouse cursor only |
| `gst-libav` and friends | Video backgrounds play as solid black |

**It tests the login screen before switching to it.** The greeter runs in test mode first. If the theme doesn't render, HermitCrab falls back to Breeze, leaves your login manager alone, and names the missing package. Switching login manager is **off by default** and writes `~/RESTORE-UNDO-LOGIN.txt` with the revert command first.

**It knows files from packages.** A widget from the KDE Store is a folder — it's copied. A widget from the AUR has compiled parts in `/usr/lib` — it's reinstalled. Same for KWin effects: ShapeCorners is a compiled plugin built for your exact KWin, so it travels as a package name, not a file.

**It writes settings in an order that sticks.**
- Plasma rewrites the panel layout when it exits, so copying it into a running session gets silently thrown away at logout. HermitCrab stops plasmashell first, writes, then restarts it.
- Applying a global theme overwrites your icon theme and cursor. So the global theme goes first, then each setting is written and verified.
- KWin effect switches and their settings (corner radius, blur strength) are written back *after* the theme, for the same reason.

**It catches customisation outside Plasma** — Quickshell, AGS, eww, waybar, rofi, dunst, matugen, swww, keyd, your `~/.local/bin` scripts.

**It tells you when it can't help.** Some desktops are whole frameworks with their own installers — [Caelestia](https://github.com/ladybug-me/caelestia-dots-kde) is one. HermitCrab detects these, says so plainly, and still carries your settings for them, so you install the framework first and HermitCrab puts your tweaks on top.

---

## Sharing safely

A **theme pack** is built to be handed to strangers.

**Never included:** SSH/GPG keys, KDE Wallet, saved passwords, browser cookies and history, WiFi/VPN credentials, shell configs (they hide API keys), keyboard shortcuts, KDE Connect pairings. Your hostname and username are removed from the pack's manifest.

Before the archive is built, the whole pack is scanned for credential file names, key files, and contents like `BEGIN PRIVATE KEY`, `api_key=` and bearer tokens. **If anything turns up, the archive is not created** and the findings are listed so you can look first. Icon files like `secrets.svg` don't trigger it — false alarms teach people to ignore warnings.

---

## Safety

### Before you restore

```bash
sudo snapper -c root list
sudo snapper -c root create --description "before restore"
```

If `/home` is a separate subvolume, snapshot it too — a root snapshot does **not** cover `~/.config`, and that's where most changes land. Check with `sudo snapper list-configs`.

Without snapper, a tarball of what gets overwritten:

```bash
tar -czf ~/hermitcrab-rollback-$(date +%F).tar.gz -C "$HOME" \
  .config .local/share/plasma .local/share/icons .local/share/color-schemes \
  .local/share/aurorae .local/share/kwin .icons
```

### If the login screen goes black

Press **Ctrl+Alt+F3**, log in, then switch to a login theme that always works:

```bash
printf '[Theme]\nCurrent=breeze\n' | sudo tee /etc/sddm.conf.d/10-theme.conf
sudo reboot
```

Still black? Put your old login manager back (the exact command is in `~/RESTORE-UNDO-LOGIN.txt`):

```bash
sudo systemctl enable --force plasmalogin.service
sudo reboot
```

### If you can't get a text console

At the boot menu press `e`, add `3` to the end of the kernel line, and boot. That gives you a text login. Then:

```bash
sudo pacman -Syu      # finishes a half-done package update
sudo reboot
```

You can start a desktop by hand, without any login manager:

```bash
dbus-run-session startplasma-wayland
```

### Roll back

```bash
sudo snapper -c root undochange NUMBER..0
```

---

## Command-line use

The backend is plain Bash and works without the app:

```bash
./scripts/kde-migrate.sh   /mnt/backupdrive    # full backup
./scripts/kde-themepack.sh /mnt/backupdrive    # theme pack
./scripts/kde-restore.sh   pack.tar.gz         # restore (asks before each step)

# full backup, password protected, leaving only the locked file
./scripts/kde-migrate.sh   /mnt/backupdrive --encrypt --delete-folder
./scripts/kde-restore.sh   kde-migrate-DATE.tar.gz.gpg   # asks for the password
```

`--encrypt` asks for the password twice. `--delete-folder` deletes the backup folder only after the archive has been read back and checked.

Keep the four `scripts/*.sh` files together — they share `kde-lib.sh`.

---

## Building the AppImage

```bash
bash packaging/build-appimage.sh
# → dist/HermitCrab-<version>-x86_64.AppImage
```

It freezes the app with PyInstaller in a throwaway virtualenv and packs it with appimagetool. Build on the oldest distro you want to support — the AppImage needs a glibc at least as new as the build machine's.

**Releases are automatic:** bump `__version__` in `hermitcrab/__init__.py`, commit, then

```bash
git tag v0.1.0
git push origin v0.1.0
```

GitHub Actions builds the AppImage on Ubuntu 22.04, self-tests it, and attaches it (plus a `.sha256`) to a release.

To check any build: `./HermitCrab-*.AppImage --self-test`

---

## Project layout

```
hermitcrab/          the app (PySide6)
  scanner.py         finds everything on this machine, groups apps with their folders
  packscan.py        reads a pack for the restore screen
  appmap.py          app → folder hints, folders that start unticked
  job.py             turns your ticks into a run of the backend scripts
  ui/                window, review tree, theme matching, app-menu launcher
scripts/             Bash backend (also usable on its own)
packaging/           AppImage build, .desktop file
.github/workflows/   CI checks and automatic releases
```

## Status and known limits

- **KDE Plasma 6 only for now.** Plasma 5 themes use different QML imports and will break. Other desktops are the plan — the app/browser/system parts are already desktop-independent.
- **Arch-based distros only** (CachyOS, EndeavourOS, Arch, Manjaro) — package handling is pacman-specific.
- App folders are matched by name. Odd ones need an entry in `appmap.py`; anything unmatched still shows up under **Other folders**, so nothing is silently dropped.
- Compiled KWin effects with no package can't be moved — they're reported instead of shipped broken.
- Frameworks with their own installers (Caelestia, end-4 dots) need that installer run first.
- No undo inside the app — use snapshots.

Issues and pull requests are welcome. With a bug report, include the saved log (**Save log** on the last screen) and the output of `--self-test`.

## Credits

The backup scripts started from the idea in [gekklee/kde-backup-and-resore-scripts](https://github.com/gekklee/kde-backup-and-resore-scripts), which covers the config-file half of the problem cleanly. Most of what's here exists because something broke during a real migration and the fix had to be found the hard way.

## Licence

GNU General Public License v3.0 — see [LICENSE](LICENSE). Provided as-is, with no warranty. You're responsible for your own system — take a snapshot.
