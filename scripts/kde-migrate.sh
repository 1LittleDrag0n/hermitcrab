#!/usr/bin/env bash
# =============================================================================
#  kde-migrate.sh — Full personal system backup (CachyOS / Arch + KDE Plasma 6)
#
#  For YOUR machines only. Includes WiFi credentials, browser profiles,
#  shell configs, SSH/GPG keys. NOT for sharing.
#
#  Usage:
#    ./kde-migrate.sh                       # → ~/kde-migrate-DATE/
#    ./kde-migrate.sh /mnt/backupdrive      # → timestamped folder inside
#    ./kde-migrate.sh /mnt/backupdrive --encrypt --delete-folder
#
#  --encrypt         password-protect the archive (AES-256, via gpg) → .tar.gz.gpg
#  --delete-folder   delete the backup folder once the archive has been read
#                    back and verified — leaves just the one archive file
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kde-lib.sh
source "$SCRIPT_DIR/kde-lib.sh" || { echo "kde-lib.sh not found next to this script"; exit 1; }

# ── Arguments ────────────────────────────────────────────────────────────────
DEST_ARG=""
ENCRYPT="${KP_ENCRYPT:-no}"
DELETE_FOLDER="${KP_DELETE_FOLDER:-no}"
while [ $# -gt 0 ]; do
    case "$1" in
        --encrypt)       ENCRYPT=yes; shift ;;
        --delete-folder) DELETE_FOLDER=yes; shift ;;
        -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
        *) [ -z "$DEST_ARG" ] && DEST_ARG="$1"; shift ;;
    esac
done

# FINAL = where the result lands. OUT = where the folder is built — normally
# the same place, but see "staging" below.
FINAL="$(resolve_dest "$DEST_ARG" "kde-migrate")"
FINAL_DIR="$(dirname "$FINAL")"
NAME="$(basename "$FINAL")"
ARCHIVE="$FINAL_DIR/$NAME.tar.gz"
[ "$ENCRYPT" = "yes" ] && ARCHIVE="$ARCHIVE.gpg"
mkdir -p "$FINAL_DIR"
OUT="$FINAL"

# Staging: with a password + delete, build the (unencrypted) folder on THIS
# computer's drive and write only the encrypted file to the backup drive. On
# SSDs/btrfs a deleted file can sometimes be recovered, so the plain copy is
# better kept off a drive that gets carried around. Falls back to building on
# the backup drive when home is short on space (or is the same drive anyway).
STAGE_ROOT="$HOME/.local/state/hermitcrab/staging"
STAGED=no
KEEP_STAGE=no
if [ "$ENCRYPT" = "yes" ] && [ "$DELETE_FOLDER" = "yes" ]; then
    mkdir -p "$STAGE_ROOT" && chmod 700 "$STAGE_ROOT"
    est="${KP_ESTIMATE_BYTES:-0}"
    free=$(df -B1 --output=avail "$STAGE_ROOT" 2>/dev/null | tail -1)
    if ! kp_same_fs "$STAGE_ROOT" "$FINAL_DIR" && [ "$est" -gt 0 ] && \
       [ "${free:-0}" -gt $(( est + 2 * 1024 * 1024 * 1024 )) ]; then
        OUT="$STAGE_ROOT/$NAME"
        STAGED=yes
    fi
fi
# the staging area must never end up inside its own backup
KP_EXCLUDES+=("$HOME/.local/state/hermitcrab")

_migrate_exit() {
    cleanup_owner_cache
    kp_forget_password
    # cancelled while writing the archive → don't leave a half file behind
    if [ "${ARCHIVING:-no}" = "yes" ] && [ -n "${ARCHIVE:-}" ]; then
        rm -f "$ARCHIVE"
    fi
    # A staged folder is a temporary plain copy: always remove it unless we
    # deliberately kept it because the archive failed.
    if [ "$STAGED" = "yes" ] && [ "$KEEP_STAGE" != "yes" ] && [ -d "$OUT" ]; then
        rm -rf "$OUT"
    fi
}
trap _migrate_exit EXIT
# Without these, a cancel (SIGTERM from the app, Ctrl+C in a terminal) kills
# bash WITHOUT running the EXIT trap — leaving the plain staged copy behind.
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

if [ "$ENCRYPT" = "yes" ]; then
    command -v gpg >/dev/null || { error "gpg is missing — install it with: sudo pacman -S gnupg"; exit 1; }
    if [ -z "${KP_PASSPHRASE_FILE:-}" ]; then
        echo ""
        echo "  This backup will be password protected."
        echo "  If you forget the password, the backup cannot be opened. There is no reset."
        kp_ask_new_password
    fi
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
if [ "$DELETE_FOLDER" = "yes" ]; then
    LOG="$FINAL_DIR/$NAME.log"     # outside the folder, so it survives deletion
else
    LOG="$OUT/backup.log"
fi
exec > >(tee -a "$LOG") 2>&1

echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  ┌───────────────────────────────────────────────┐
  │   K D E   M I G R A T E   ·   full backup     │
  └───────────────────────────────────────────────┘
BANNER
echo -e "${NC}"
echo "  Destination : $OUT"
echo "  Archive     : $ARCHIVE"
echo "  Started     : $(date)"
[ "$ENCRYPT" = "yes" ] && echo "  Password    : yes (AES-256)"
[ "$DELETE_FOLDER" = "yes" ] && echo "  Folder      : deleted after the archive is verified"
[ "$STAGED" = "yes" ] && echo "  Building on : this computer's drive (only the locked file goes to the backup drive)"
echo ""
echo -e "  ${RED}⚠  Contains WiFi passwords, SSH/GPG keys, browser data.${NC}"
echo -e "  ${RED}   Keep this archive private. Do NOT share it.${NC}"

build_owner_cache

# =============================================================================
header "1 · KDE Plasma configuration"
# =============================================================================
mkdir -p "$OUT/kde-config/config" "$OUT/kde-config/dirs"

for cfg in \
    plasmarc plasma-org.kde.plasma.desktop-appletsrc plasmashellrc \
    kwinrc kwinrulesrc kdeglobals kcminputrc kglobalshortcutsrc \
    kscreenlockerrc ksmserverrc ksplashrc breezerc kxkbrc khotkeysrc \
    kded5rc kded6rc dolphinrc konsolerc spectaclerc krunnerrc \
    kwalletrc kwallet5rc mimeapps.list kiorc powerdevilrc \
    kactivitymanagerdrc plasmanotifyrc kwinrulesrc \
    systemsettingsrc kfontinstuirc gtkrc gtkrc-2.0; do
    safe_copy "$HOME/.config/$cfg" "$OUT/kde-config/config/$cfg"
done

for d in plasma-workspace kde.org systemsettings kdeconnect autostart \
         kglobalaccel kdedefaults menus; do
    safe_copy_dir "$HOME/.config/$d" "$OUT/kde-config/dirs/$d"
done

safe_copy_dir "$HOME/.local/share/konsole"       "$OUT/kde-config/konsole"
safe_copy_dir "$HOME/.local/share/kxmlgui5"      "$OUT/kde-config/kxmlgui5"
safe_copy_dir "$HOME/.local/share/kservices5"    "$OUT/kde-config/kservices5"
safe_copy_dir "$HOME/.local/share/kwalletd"      "$OUT/kde-config/kwalletd"

# =============================================================================
header "2 · Themes"
# =============================================================================
T="$OUT/themes"; mkdir -p "$T"

safe_copy_dir "$HOME/.local/share/plasma/desktoptheme"  "$T/desktoptheme"
safe_copy_dir "$HOME/.local/share/plasma/look-and-feel" "$T/look-and-feel"
safe_copy_dir "$HOME/.local/share/color-schemes"        "$T/color-schemes"
safe_copy_dir "$HOME/.local/share/aurorae"              "$T/aurorae"
safe_copy_dir "$HOME/.local/share/kwin"                 "$T/kwin"
safe_copy_dir "$HOME/.local/share/kstyle"               "$T/kstyle"
safe_copy_dir "$HOME/.config/Kvantum"                   "$T/Kvantum"
safe_copy_dir "$HOME/.local/share/Kvantum"              "$T/Kvantum-local"

# System themes that are NOT package-owned (yours)
mkdir -p "$T/system-unowned"
for base in /usr/share/plasma/desktoptheme /usr/share/plasma/look-and-feel \
            /usr/share/aurorae/themes /usr/share/color-schemes /usr/share/Kvantum; do
    [ -d "$base" ] || continue
    for d in "$base"/*/; do
        [ -d "$d" ] || continue
        if [ -z "$(owner_of "$d")" ]; then
            rel="${d#/usr/share/}"
            mkdir -p "$T/system-unowned/$(dirname "$rel")"
            kp_cp "$d" "$T/system-unowned/$rel" 2>/dev/null && \
                success "Unowned system theme: $rel"
        fi
    done
done

# =============================================================================
header "3 · Icons & cursors"
# =============================================================================
I="$OUT/icons"; mkdir -p "$I"
safe_copy_dir "$HOME/.local/share/icons" "$I/local-share-icons"
safe_copy_dir "$HOME/.icons"             "$I/dot-icons"

# Unowned system cursor/icon themes
mkdir -p "$I/system-unowned"
for d in /usr/share/icons/*/; do
    [ -d "$d" ] || continue
    if [ -z "$(owner_of "$d")" ]; then
        kp_cp "$d" "$I/system-unowned/$(basename "$d")" 2>/dev/null && \
            success "Unowned system icon/cursor: $(basename "$d")"
    fi
done

{
    echo "cursorTheme=$(grep -m1 '^cursorTheme=' "$HOME/.config/kcminputrc" 2>/dev/null | cut -d= -f2-)"
    echo "cursorSize=$(grep  -m1 '^cursorSize='  "$HOME/.config/kcminputrc" 2>/dev/null | cut -d= -f2-)"
} > "$I/cursor-settings"
safe_copy "$HOME/.icons/default" "$I/x11-default"

# =============================================================================
header "4 · Fonts"
# =============================================================================
F="$OUT/fonts"; mkdir -p "$F"
safe_copy_dir "$HOME/.local/share/fonts" "$F/local-fonts"
safe_copy_dir "$HOME/.fonts"             "$F/dot-fonts"
safe_copy_dir "$HOME/.config/fontconfig" "$F/fontconfig"
pacman -Qqe 2>/dev/null | grep -iE 'font|nerd|ttf|otf|noto' > "$F/font-packages.txt"

# =============================================================================
header "5 · SDDM"
# =============================================================================
S="$OUT/sddm"; mkdir -p "$S/themes"
safe_copy     /etc/sddm.conf   "$S/sddm.conf"
safe_copy_dir /etc/sddm.conf.d "$S/sddm.conf.d"

for d in /usr/share/sddm/themes/*/; do
    [ -d "$d" ] || continue
    tname=$(basename "$d")
    if [ -z "$(owner_of "$d")" ]; then
        kp_cp "$d" "$S/themes/$tname" 2>/dev/null && success "SDDM theme (yours): $tname"
    else
        skipmsg "SDDM theme $tname → package $(owner_of "$d")"
    fi
done
safe_copy_dir "$HOME/.local/share/sddm" "$S/user-sddm"

# =============================================================================
header "6 · Widgets & KWin effects"
# =============================================================================
W="$OUT/widgets"; mkdir -p "$W/files"
classify_plasmoids "$W/plasmoids"

while IFS= read -r d; do
    [ -d "$d" ] || continue
    kp_cp "$d" "$W/files/$(basename "$d")" 2>/dev/null
done < "$W/plasmoids.files"

safe_copy_dir "$HOME/.local/share/kwin/scripts" "$W/kwin-scripts"
safe_copy_dir "$HOME/.local/share/kwin/effects" "$W/kwin-effects"

# Record which effects/scripts are enabled
grep -E 'Enabled=(true|false)' "$HOME/.config/kwinrc" 2>/dev/null > "$W/kwin-enabled.txt"

# =============================================================================
header "7 · GTK"
# =============================================================================
G="$OUT/gtk"; mkdir -p "$G"
safe_copy     "$HOME/.config/gtk-3.0"     "$G/gtk-3.0"
safe_copy     "$HOME/.config/gtk-4.0"     "$G/gtk-4.0"
safe_copy     "$HOME/.gtkrc-2.0"          "$G/gtkrc-2.0"
safe_copy_dir "$HOME/.local/share/themes" "$G/themes"
safe_copy_dir "$HOME/.themes"             "$G/dot-themes"

# =============================================================================
header "8 · Wallpapers"
# =============================================================================
WP="$OUT/wallpapers"; mkdir -p "$WP"
if [ -d "$HOME/Pictures" ]; then
    find "$HOME/Pictures" -maxdepth 4 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
           -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.mp4' \) 2>/dev/null | \
    while read -r f; do
        rel="${f#$HOME/Pictures/}"
        mkdir -p "$WP/Pictures/$(dirname "$rel")"
        kp_cp "$f" "$WP/Pictures/$rel"
    done
    success "Wallpapers from ~/Pictures"
fi
safe_copy_dir "$HOME/.local/share/wallpapers" "$WP/local-wallpapers"

# Record which wallpapers are actually in use
grep -oP '(?<=^Image=).*' "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null | \
    sort -u > "$WP/in-use.txt"

# =============================================================================
header "9 · Packages"
# =============================================================================
P="$OUT/packages"; mkdir -p "$P"
pacman -Qqe  > "$P/explicit.txt"
pacman -Qqen > "$P/native.txt"
pacman -Qqem > "$P/aur.txt"
pacman -Qq   > "$P/all-installed.txt"
for _f in explicit native aur; do filter_pkgs "$P/$_f.txt"; done
success "Native: $(wc -l < "$P/native.txt")  AUR: $(wc -l < "$P/aur.txt")"

safe_copy     /etc/pacman.conf    "$P/pacman.conf"
safe_copy_dir /etc/pacman.d/hooks "$P/hooks"

if command -v flatpak &>/dev/null && ! is_excluded "@flatpak"; then
    flatpak list --app --columns=application > "$P/flatpak.txt"
    filter_pkgs "$P/flatpak.txt"
    success "Flatpak list"
fi

# Enabled systemd services
systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | \
    awk '{print $1}' > "$P/systemd-enabled.txt"
systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | \
    awk '{print $1}' > "$P/systemd-user-enabled.txt"

# =============================================================================
header "10 · App configs & dotfiles"
# =============================================================================
A="$OUT/apps"; mkdir -p "$A/config" "$A/home" "$A/local"

if [ "${KP_GUI:-0}" = "1" ]; then
    info "App folders were chosen in HermitCrab — see section 10b"
else
for app in \
    fish zsh bash starship.toml \
    nvim vim helix \
    alacritty kitty wezterm foot ghostty \
    htop btop fastfetch neofetch \
    mpv vlc \
    Code VSCodium code-flags.conf \
    obsidian discord \
    spicetify \
    MangoHud vkBasalt gamemode \
    Thunar pcmanfm ranger lf yazi \
    rofi wofi dunst \
    OpenRGB \
    qt5ct qt6ct \
    nwg-look \
    keepassxc \
    syncthing \
    micro zellij tmux \
    gh git lazygit \
    pipewire wireplumber \
    autostart-scripts; do
    safe_copy "$HOME/.config/$app" "$A/config/$app"
done
fi

for f in .bashrc .bash_profile .bash_aliases .bash_logout \
         .zshrc .zprofile .zshenv .zlogin \
         .profile .inputrc .gitconfig .gitignore_global \
         .tmux.conf .vimrc .editorconfig .Xresources .xinitrc; do
    safe_copy "$HOME/$f" "$A/home/$f"
done

safe_copy_dir "$HOME/.local/bin"                "$A/local/bin"
# ~/.local/share/applications is skipped on purpose: launchers are
# recreated by package installs, copying them leaves ghost menu entries.
safe_copy_dir "$HOME/.local/share/mime"         "$A/local/mime"

# =============================================================================
if [ -n "${KP_INCLUDE_FILE:-}" ] && [ -s "$KP_INCLUDE_FILE" ]; then
header "10b · App data selected in HermitCrab"
# =============================================================================
# Stored mirrored under apps/extra/home/ so restore can drop it back in place.
XH="$A/extra/home"; mkdir -p "$XH"
while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    case "$p" in
        "$HOME"/*) rel="${p#"$HOME"/}" ;;
        *) warn "Outside your home folder, skipped: $p"; continue ;;
    esac
    mkdir -p "$XH/$(dirname "$rel")"
    kp_cp "$p" "$XH/$(dirname "$rel")/" 2>/dev/null && success "App data: ~/$rel" || \
        warn "Copy failed: ~/$rel"
done < "$KP_INCLUDE_FILE"
fi

# =============================================================================
header "11 · Browsers (full profiles)"
# =============================================================================
B="$OUT/browsers"; mkdir -p "$B"

# Only true secret stores are excluded; history/bookmarks/cookies kept.
BROWSER_EXCLUDE=(
    --exclude='key3.db' --exclude='key4.db'
    --exclude='logins.json' --exclude='signons.sqlite'
    --exclude='Login Data' --exclude='Login Data For Account'
    --exclude='Login Data-journal'
    --exclude='Cache' --exclude='Code Cache' --exclude='GPUCache'
    --exclude='ShaderCache' --exclude='DawnCache' --exclude='DawnGraphiteCache'
    --exclude='Service Worker' --exclude='CacheStorage'
    --exclude='component_crx_cache' --exclude='OnDeviceHeadSuggestModel'
    --exclude='cache2' --exclude='startupCache' --exclude='thumbnails'
    --exclude='minidumps' --exclude='crashes'
)

copy_profile() {
    local src="$1" dst="$2"
    [ -d "$src" ] || return
    if is_excluded "$src"; then skipmsg "Excluded: $(_kp_short "$src")"; return; fi
    mkdir -p "$dst"
    if command -v rsync &>/dev/null; then
        local -a extra=(); local r
        while IFS= read -r r; do [ -n "$r" ] && extra+=("--exclude=/$r"); done < <(_kp_excluded_children "$src")
        rsync -a "${BROWSER_EXCLUDE[@]}" "${extra[@]}" "$src/" "$dst/" 2>/dev/null
    else
        cp -a "$src/." "$dst/" 2>/dev/null
        for pat in key4.db logins.json 'Login Data' Cache GPUCache; do
            find "$dst" -name "$pat" -exec rm -rf {} + 2>/dev/null
        done
    fi
    success "Profile: $(basename "$src")"
}

BRAVE="$HOME/.config/BraveSoftware/Brave-Browser"
if [ -d "$BRAVE" ] && ! is_excluded "$BRAVE"; then
    mkdir -p "$B/brave"
    safe_copy "$BRAVE/Local State" "$B/brave/Local State"
    for p in "$BRAVE/Default" "$BRAVE"/Profile\ *; do
        [ -d "$p" ] && copy_profile "$p" "$B/brave/$(basename "$p")"
    done
fi

for pair in "zen:$HOME/.zen" "firefox:$HOME/.mozilla/firefox"; do
    name="${pair%%:*}"; dir="${pair#*:}"
    [ -d "$dir" ] || continue
    if is_excluded "$dir"; then skipmsg "Excluded: $name"; continue; fi
    mkdir -p "$B/$name"
    safe_copy "$dir/profiles.ini" "$B/$name/profiles.ini"
    safe_copy "$dir/installs.ini" "$B/$name/installs.ini"
    while IFS= read -r pp; do
        [ -d "$dir/$pp" ] && copy_profile "$dir/$pp" "$B/$name/$pp"
    done < <(grep -oP '(?<=Path=).*' "$dir/profiles.ini" 2>/dev/null)
done

# =============================================================================
header "12 · Network & power"
# =============================================================================
N="$OUT/network"; mkdir -p "$N"
if [ -d /etc/NetworkManager/system-connections ] && ! is_excluded /etc/NetworkManager/system-connections; then
    if sudo cp -a /etc/NetworkManager/system-connections "$N/nm-connections" 2>/dev/null; then
        sudo chown -R "$USER:$USER" "$N/nm-connections"
        chmod -R 600 "$N/nm-connections"/* 2>/dev/null
        success "NetworkManager connections (WiFi/VPN)"
    else
        warn "Could not read NetworkManager connections"
    fi
fi
safe_copy /etc/tlp.conf          "$N/tlp.conf"
safe_copy /etc/auto-cpufreq.conf "$N/auto-cpufreq.conf"
safe_copy /etc/hosts             "$N/hosts"
safe_copy /etc/fstab             "$N/fstab.reference"

# =============================================================================
header "13 · SSH & GPG"
# =============================================================================
K="$OUT/keys"; mkdir -p "$K"; chmod 700 "$K"
if [ -d "$HOME/.ssh" ] && ! is_excluded "$HOME/.ssh"; then
    kp_cp "$HOME/.ssh" "$K/ssh" && chmod -R 700 "$K/ssh" && success "SSH keys"
fi
if command -v gpg &>/dev/null && ! is_excluded "@gpg"; then
    gpg --export --armor             > "$K/gpg-public.asc"     2>/dev/null
    gpg --export-secret-keys --armor > "$K/gpg-private.asc"    2>/dev/null
    gpg --export-ownertrust          > "$K/gpg-ownertrust.txt" 2>/dev/null
    chmod 600 "$K"/gpg-*.asc 2>/dev/null
    success "GPG keys"
fi

# =============================================================================
header "14 · Misc"
# =============================================================================
M="$OUT/misc"; mkdir -p "$M"
is_excluded "@crontab" || crontab -l > "$M/crontab.txt" 2>/dev/null
safe_copy_dir "$HOME/.config/systemd"       "$M/systemd-user"
safe_copy     "$HOME/.config/environment.d" "$M/environment.d"
safe_copy     "$HOME/.config/user-dirs.dirs" "$M/user-dirs.dirs"

# =============================================================================
header "Finalising"
# =============================================================================
write_manifest "$OUT" "migrate" "no"

# Dependency scan for reference
scan_qml_deps "$OUT/qml-deps.txt" \
    /usr/share/sddm/themes \
    "$HOME/.local/share/plasma" \
    "$HOME/.local/share/kwin" \
    "$HOME/.local/share/aurorae"
success "QML dependency list written"

if [ "$ENCRYPT" = "yes" ]; then
    info "Compressing and encrypting (AES-256)..."
else
    info "Compressing (excluding snapshots)..."
fi
ARCHIVE_OK=no
ARCHIVING=yes
kp_make_archive "$OUT" "$ARCHIVE" "$ENCRYPT"
make_rc=$?
ARCHIVING=no
if [ $make_rc -eq 0 ]; then
    ARCHIVE_OK=yes
    success "Archive created: $(basename "$ARCHIVE")"
    [ "$ENCRYPT" = "yes" ] && chmod 600 "$ARCHIVE"
else
    error "Archive creation failed"
fi

FOLDER_DELETED=no
if [ "$DELETE_FOLDER" = "yes" ]; then
    if [ "$ARCHIVE_OK" != "yes" ]; then
        KEEP_STAGE=yes
        warn "Keeping the folder because the archive could not be created"
    else
        info "Verifying the archive (reading every file back)..."
        if kp_verify_archive "$ARCHIVE"; then
            success "Archive verified — every file reads back correctly"
            rm -rf "$OUT" && FOLDER_DELETED=yes && success "Backup folder deleted"
        else
            KEEP_STAGE=yes
            ARCHIVE_OK=no
            error "Verification FAILED — the archive is damaged. Keeping the folder."
        fi
    fi
fi

echo ""
if [ "$ARCHIVE_OK" = "yes" ]; then
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        MIGRATE BACKUP COMPLETE         ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════╝${NC}"
else
echo -e "${BOLD}${RED}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║      BACKUP FINISHED WITH PROBLEMS     ║${NC}"
echo -e "${BOLD}${RED}╚════════════════════════════════════════╝${NC}"
fi
echo ""
if [ "$FOLDER_DELETED" != "yes" ] && [ -d "$OUT" ]; then
echo -e "  Folder  : ${CYAN}$OUT${NC}  ($(du -sh "$OUT" 2>/dev/null | cut -f1))"
fi
[ -f "$ARCHIVE" ] && \
echo -e "  Archive : ${CYAN}$ARCHIVE${NC}  ($(du -sh "$ARCHIVE" 2>/dev/null | cut -f1))"
[ "$DELETE_FOLDER" = "yes" ] && echo -e "  Log     : ${CYAN}$LOG${NC}"
echo ""
if [ "$ENCRYPT" = "yes" ] && [ "$ARCHIVE_OK" = "yes" ]; then
echo -e "  ${GREEN}🔒 Password protected (AES-256).${NC}"
echo -e "  ${YELLOW}   If you forget the password, this backup cannot be opened. There is no reset.${NC}"
else
echo -e "  ${RED}⚠  PRIVATE — contains keys and credentials. Do not share.${NC}"
fi
echo ""
echo    "  Restore with:  ./kde-restore.sh $ARCHIVE"
echo ""
[ "$ARCHIVE_OK" = "yes" ] || exit 1
