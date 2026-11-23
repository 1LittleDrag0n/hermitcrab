#!/usr/bin/env bash
# =============================================================================
#  kde-restore.sh — Restores either a kde-migrate or kde-themepack archive
#  Auto-detects which type from the MANIFEST.
#
#  Usage:
#    ./kde-restore.sh kde-migrate-DATE.tar.gz
#    ./kde-restore.sh kde-themepack-DATE.tar.gz
#    ./kde-restore.sh /path/to/extracted-folder/
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kde-lib.sh
source "$SCRIPT_DIR/kde-lib.sh" || { echo "kde-lib.sh not found next to this script"; exit 1; }

SRC="${1:-}"
if [ -z "$SRC" ]; then
    echo "Usage: $0 <archive.tar.gz | archive.tar.gz.gpg | folder>"
    exit 1
fi

CLEANUP=false
if [[ "$SRC" == *.tar.gz || "$SRC" == *.tgz || "$SRC" == *.gpg ]]; then
    # Extract next to the archive: /tmp is RAM on most distros and too small
    # for a full backup.
    TMP="$(mktemp -d -p "$(dirname "$SRC")" .kde-restore-XXXXXX 2>/dev/null || mktemp -d)"
    chmod 700 "$TMP"
    if [[ "$SRC" == *.gpg ]]; then
        info "This backup is password protected — enter its password to unlock it."
    fi
    info "Extracting..."
    kp_extract_archive "$SRC" "$TMP"
    rc=$?
    if [ $rc -eq 2 ]; then
        rm -rf "$TMP"
        error "Wrong password — nothing was changed."
        exit 2
    elif [ $rc -ne 0 ]; then
        rm -rf "$TMP"
        error "Extraction failed — the file may be damaged. Nothing was changed."
        exit 1
    fi
    IN="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)"
    CLEANUP=true
else
    IN="${SRC%/}"
fi

[ -d "$IN" ] || { error "Not found: $IN"; exit 1; }

LOG="$HOME/kde-restore-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

TYPE="$(read_manifest_key "$IN" TYPE)"
[ -z "$TYPE" ] && TYPE="unknown"

echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  ┌───────────────────────────────────────────────┐
  │   K D E   R E S T O R E                       │
  └───────────────────────────────────────────────┘
BANNER
echo -e "${NC}"
echo "  Source : $IN"
echo "  Type   : $TYPE"
echo "  Log    : $LOG"
echo ""

if [ -f "$IN/MANIFEST" ]; then
    sed 's/^/    /' "$IN/MANIFEST"
    echo ""
fi

# ── Plasma version compatibility check ────────────────────────────────────────
SRC_PLASMA="$(read_manifest_key "$IN" PLASMA)"
CUR_PLASMA="$(plasmashell --version 2>/dev/null | awk '{print $2}')"
if [ -n "$SRC_PLASMA" ] && [ -n "$CUR_PLASMA" ]; then
    if [ "${SRC_PLASMA%%.*}" != "${CUR_PLASMA%%.*}" ]; then
        echo ""
        error "Plasma major version mismatch!"
        echo "    Pack was made on Plasma $SRC_PLASMA"
        echo "    This system runs Plasma $CUR_PLASMA"
        echo "    Themes and widgets will very likely break."
        echo ""
        ask "Continue anyway?" "n" || { info "Aborted."; exit 0; }
    else
        success "Plasma version compatible ($CUR_PLASMA)"
    fi
fi

# ── Tier 3 notice ────────────────────────────────────────────────────────────
if [ -f "$IN/TIER3-REPORT" ]; then
    echo ""
    error "═══ THIS PACK CAME FROM A SETUP WITH ITS OWN INSTALLER ═══"
    echo ""
    warn "The source system uses these components:"
    while IFS='|' read -r kind item note; do
        printf "    %-6s %-32s %s\n" "[$kind]" "$item" "$note"
    done < "$IN/TIER3-REPORT"
    echo ""
    warn "Copying config files alone will NOT reproduce them — the widgets"
    warn "will not start, and the desktop may look broken."
    echo ""
    info "Correct order:"
    info "  1. Install the upstream project first (its own git repo + setup script)"
    info "  2. Then run this restore for the Plasma themes and personal tweaks"
    echo ""
    info "What this pack CAN reliably give you: Plasma/global themes, colour"
    info "schemes, icons, cursors, fonts, SDDM login theme, KWin effects."
    echo ""
    ask "Continue anyway?" "n" || { info "Aborted."; exit 0; }
fi

warn "This overwrites your current KDE appearance settings."
ask "Continue?" || { info "Aborted."; exit 0; }

# =============================================================================
header "Step 1 · Packages"
# =============================================================================
install_list() {
    local file="$1" kind="$2"
    [ -s "$file" ] || return
    local total
    total=$(grep -cve '^\s*$' "$file")
    echo ""
    info "$kind packages to install ($total):"
    sed 's/^/    /' "$file"
    echo ""
    ask "Install these $kind packages?" || return

    local helper="sudo pacman"
    if [ "$kind" = "AUR" ]; then
        helper=""
        command -v yay  &>/dev/null && helper="yay"
        command -v paru &>/dev/null && helper="paru"
        if [ -z "$helper" ]; then
            warn "No AUR helper found. Install yay or paru, then run:"
            warn "  yay -S --needed - < $file"
            return
        fi
    fi

    # Try the whole list in one transaction first — much faster.
    info "Installing in one batch..."
    if $helper -S --needed --noconfirm - < "$file" 2>/dev/null; then
        success "All $kind packages installed"
        return
    fi

    # Batch failed (usually one bad name aborts the transaction).
    # Fall back to one-at-a-time so a single missing package doesn't
    # block everything else.
    warn "Batch install failed — retrying one package at a time"
    local failed=0 ok=0
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if $helper -S --needed --noconfirm "$pkg" &>/dev/null; then
            ok=$((ok+1))
        else
            warn "  could not install: $pkg"
            echo "$pkg" >> "$HOME/kde-restore-failed-packages.txt"
            failed=$((failed+1))
        fi
    done < "$file"
    success "$ok installed, $failed failed"
    [ "$failed" -gt 0 ] && \
        warn "Failed list saved to ~/kde-restore-failed-packages.txt"
}

if [ "$TYPE" = "themepack" ]; then
    # CRITICAL: never run `pacman -Sy` followed by installing specific packages.
    # That is a partial upgrade and it WILL break the system (mismatched libs,
    # black screen at login). Always do a full -Syu, or nothing at all.
    echo ""
    warn "Installing packages requires a FULL system update first."
    warn "Installing into a partially-updated system breaks Plasma."
    if ask "Run a full system update now (sudo pacman -Syu)?"; then
        if ! sudo pacman -Syu --noconfirm; then
            error "System update failed — skipping package installation."
            error "Fix the update first, then re-run this script."
            SKIP_PACKAGES=yes
        fi
    else
        warn "Skipping package installation entirely (safer than a partial upgrade)."
        warn "Theme files will still be restored; install deps later with:"
        warn "  sudo pacman -Syu && sudo pacman -S --needed - < dependencies/native.txt"
        SKIP_PACKAGES=yes
    fi

    # An AUR helper is needed if the pack has AUR dependencies
    if [ -s "$IN/dependencies/aur.txt" ] && \
       ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
        warn "This pack needs AUR packages but no AUR helper is installed."
        if ask "Install 'yay' now? (builds from source, needs base-devel)"; then
            sudo pacman -S --needed --noconfirm git base-devel
            tmpdir=$(mktemp -d)
            git clone https://aur.archlinux.org/yay-bin.git "$tmpdir/yay-bin" && \
                ( cd "$tmpdir/yay-bin" && makepkg -si --noconfirm ) && \
                success "yay installed"
            rm -rf "$tmpdir"
        fi
    fi

    if [ "${SKIP_PACKAGES:-no}" != "yes" ]; then
        install_list "$IN/dependencies/native.txt" "native"
        install_list "$IN/dependencies/aur.txt"    "AUR"
    fi

    if [ -s "$IN/dependencies/unresolved.txt" ]; then
        echo ""
        warn "These were not in the source machine's repos — you may need them from AUR:"
        sed 's/^/    /' "$IN/dependencies/unresolved.txt"
    fi
elif [ -d "$IN/packages" ]; then
    warn "A full system update is required before installing packages."
    if ask "Run sudo pacman -Syu now?"; then
        sudo pacman -Syu --noconfirm || { error "Update failed"; SKIP_PACKAGES=yes; }
    else
        SKIP_PACKAGES=yes
        warn "Skipping package installation (partial upgrades break Arch)."
    fi
    if [ "${SKIP_PACKAGES:-no}" != "yes" ]; then
        install_list "$IN/packages/native.txt" "native"
        install_list "$IN/packages/aur.txt"    "AUR"
    fi
    if [ -s "$IN/packages/flatpak.txt" ] && command -v flatpak &>/dev/null; then
        if ask "Install Flatpak apps?"; then
            while read -r app; do
                [ -z "$app" ] && continue
                flatpak install -y --noninteractive "$app" 2>/dev/null || \
                    warn "Flatpak failed: $app"
            done < "$IN/packages/flatpak.txt"
        fi
    fi
fi

# =============================================================================
header "Step 2 · Appearance settings"
# =============================================================================
CFG_SRC="$IN/config"; [ -d "$IN/kde-config/config" ] && CFG_SRC="$IN/kde-config/config"

# CRITICAL: plasmashell keeps the panel layout in memory and rewrites
# plasma-org.kde.plasma.desktop-appletsrc when it exits. Copying that file
# while plasmashell is running means the change is silently discarded on
# logout — this is why panels and widgets "disappear" after a restore.
# So: stop plasmashell first, write the configs, then start it again.
PLASMA_WAS_RUNNING=no
stop_plasmashell() {
    if pgrep -x plasmashell &>/dev/null; then
        PLASMA_WAS_RUNNING=yes
        info "Stopping plasmashell so the panel layout can be written safely..."
        kquitapp6 plasmashell &>/dev/null || killall plasmashell &>/dev/null
        sleep 3
        pgrep -x plasmashell &>/dev/null && { killall -9 plasmashell &>/dev/null; sleep 1; }
        success "plasmashell stopped"
    fi
}
start_plasmashell() {
    if [ "$PLASMA_WAS_RUNNING" = "yes" ]; then
        info "Restarting plasmashell..."
        (setsid plasmashell --replace &>/dev/null &) 
        sleep 4
        success "plasmashell restarted"
    fi
}

if [ -d "$CFG_SRC" ] && ask "Restore Plasma appearance config (panels, widgets)?"; then
    stop_plasmashell
    for f in "$CFG_SRC"/*; do
        [ -f "$f" ] || continue
        safe_restore "$f" "$HOME/.config/$(basename "$f")"
    done
    for d in "$CFG_SRC"/*/; do
        [ -d "$d" ] || continue
        safe_restore_dir "$d" "$HOME/.config/$(basename "$d")"
    done
    if [ -d "$IN/kde-config/dirs" ]; then
        for d in "$IN/kde-config/dirs"/*/; do
            [ -d "$d" ] || continue
            safe_restore_dir "$d" "$HOME/.config/$(basename "$d")"
        done
    fi
    [ -d "$IN/config/Kvantum"     ] && safe_restore_dir "$IN/config/Kvantum"     "$HOME/.config/Kvantum"
    [ -d "$IN/config/konsole"     ] && safe_restore_dir "$IN/config/konsole"     "$HOME/.local/share/konsole"
    [ -d "$IN/kde-config/konsole" ] && safe_restore_dir "$IN/kde-config/konsole" "$HOME/.local/share/konsole"
fi

# =============================================================================
header "Step 3 · Themes"
# =============================================================================
if [ -d "$IN/themes" ] && ask "Restore themes?"; then
    T="$IN/themes"
    safe_restore_dir "$T/desktoptheme"  "$HOME/.local/share/plasma/desktoptheme"
    safe_restore_dir "$T/look-and-feel" "$HOME/.local/share/plasma/look-and-feel"
    safe_restore_dir "$T/color-schemes" "$HOME/.local/share/color-schemes"
    safe_restore_dir "$T/aurorae"       "$HOME/.local/share/aurorae"
    safe_restore_dir "$T/kwin"          "$HOME/.local/share/kwin"
    safe_restore_dir "$T/kstyle"        "$HOME/.local/share/kstyle"
    [ -d "$T/Kvantum"       ] && safe_restore_dir "$T/Kvantum"       "$HOME/.local/share/Kvantum"
    [ -d "$T/Kvantum-local" ] && safe_restore_dir "$T/Kvantum-local" "$HOME/.local/share/Kvantum"

    if [ -d "$T/system-unowned" ]; then
        info "Installing system-wide themes (needs sudo)..."
        sudo cp -a "$T/system-unowned/." /usr/share/ 2>/dev/null && \
            success "System themes installed" || \
            warn "Could not install system themes"
    fi
fi

# =============================================================================
header "Step 4 · Icons & cursors"
# =============================================================================
if [ -d "$IN/icons" ] && ask "Restore icons and cursors?"; then
    I="$IN/icons"
    [ -d "$I/local-icons"       ] && safe_restore_dir "$I/local-icons"       "$HOME/.local/share/icons"
    [ -d "$I/local-share-icons" ] && safe_restore_dir "$I/local-share-icons" "$HOME/.local/share/icons"
    [ -d "$I/dot-icons"         ] && safe_restore_dir "$I/dot-icons"         "$HOME/.icons"

    if [ -d "$I/system-unowned" ]; then
        sudo mkdir -p /usr/share/icons
        sudo cp -a "$I/system-unowned/." /usr/share/icons/ 2>/dev/null && \
            success "System icon/cursor themes installed"
    fi

    [ -e "$I/x11-default" ] && safe_restore "$I/x11-default" "$HOME/.icons/default"

    CURSOR=""
    [ -f "$I/cursor-settings" ] && \
        CURSOR=$(grep -m1 '^cursorTheme=' "$I/cursor-settings" | cut -d= -f2-)
    [ -z "$CURSOR" ] && [ -f "$IN/ACTIVE-THEME" ] && \
        CURSOR=$(grep -m1 '^cursorTheme=' "$IN/ACTIVE-THEME" | cut -d= -f2-)

    if [ -n "$CURSOR" ]; then
        mkdir -p "$HOME/.icons/default"
        printf '[Icon Theme]\nInherits=%s\n' "$CURSOR" > "$HOME/.icons/default/index.theme"
        success "Cursor set to: $CURSOR"
    fi
fi

# =============================================================================
header "Step 5 · Fonts"
# =============================================================================
if [ -d "$IN/fonts" ] && ask "Restore fonts?"; then
    safe_restore_dir "$IN/fonts/local-fonts" "$HOME/.local/share/fonts"
    safe_restore_dir "$IN/fonts/dot-fonts"   "$HOME/.fonts"
    safe_restore_dir "$IN/fonts/fontconfig"  "$HOME/.config/fontconfig"
    fc-cache -f &>/dev/null && success "Font cache rebuilt"
fi

# =============================================================================
header "Step 6 · SDDM login theme"
# =============================================================================
if [ -d "$IN/sddm" ] && ask "Restore SDDM login theme? (sudo)"; then
    S="$IN/sddm"

    CURRENT_DM=$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null)
    info "Current display manager: ${CURRENT_DM:-none}"

    THEME_NAME=""
    [ -f "$IN/ACTIVE-THEME" ] && \
        THEME_NAME=$(grep -m1 '^sddmTheme=' "$IN/ACTIVE-THEME" | cut -d= -f2-)

    # ── 1. Install the theme files ───────────────────────────────────────────
    if [ -d "$S/themes" ] && [ -n "$(ls -A "$S/themes" 2>/dev/null)" ]; then
        sudo mkdir -p /usr/share/sddm/themes
        sudo cp -a "$S/themes/." /usr/share/sddm/themes/ && success "Theme files installed"
    fi

    if [ -z "$THEME_NAME" ] || [ ! -d "/usr/share/sddm/themes/$THEME_NAME" ]; then
        warn "No custom login theme to configure — skipping"
    else

    # ── 2. Work out whether this theme is Qt5 or Qt6 ─────────────────────────
    # Getting this wrong is what causes a black login screen: the wrong greeter
    # cannot resolve the theme's imports and silently loads the built-in theme.
    THEME_QT=""
    [ -f "$S/theme-qt-versions" ] && \
        THEME_QT=$(grep -m1 "^$THEME_NAME=" "$S/theme-qt-versions" | cut -d= -f2-)
    [ -z "$THEME_QT" ] && \
        THEME_QT=$(detect_qt_version "/usr/share/sddm/themes/$THEME_NAME")
    info "Login theme '$THEME_NAME' is Qt$THEME_QT"

    META="/usr/share/sddm/themes/$THEME_NAME/metadata.desktop"
    if [ -f "$META" ]; then
        sudo sed -i '/^QtVersion=/d' "$META"
        if [ "$THEME_QT" = "6" ]; then
            echo "QtVersion=6" | sudo tee -a "$META" >/dev/null
        fi
    fi

    # ── 3. Install the matching Qt runtime ───────────────────────────────────
    # These lists include the pieces that QML import scanning cannot see:
    # the Wayland platform plugin and the layer-shell integration. Missing
    # either one gives a black login screen with NO error in the journal.
    if [ "$THEME_QT" = "5" ]; then
        QT_PKGS="qt5-declarative qt5-graphicaleffects qt5-quickcontrols2 \
                 qt5-quickcontrols qt5-svg qt5-multimedia qt5-base qt5-wayland"
        LAYER_PKG="layer-shell-qt5"
        GREETER="sddm-greeter"
    else
        QT_PKGS="qt6-declarative qt6-5compat qt6-svg qt6-multimedia qt6-wayland"
        LAYER_PKG="layer-shell-qt"
        GREETER="sddm-greeter-qt6"
    fi

    # Video backgrounds decode through GStreamer; without gst-libav the video
    # element loads without error and renders solid black.
    if find "/usr/share/sddm/themes/$THEME_NAME" -type f \
        \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' \
           -o -iname '*.mov' \) 2>/dev/null | grep -q .; then
        QT_PKGS="$QT_PKGS gst-libav gst-plugins-base gst-plugins-good gst-plugins-bad"
        info "Theme has video assets — GStreamer codecs required"
    fi

    MISSING=""
    for p in $QT_PKGS; do
        pacman -Qq "$p" &>/dev/null || MISSING="$MISSING $p"
    done
    if [ -n "$MISSING" ]; then
        warn "Login theme needs:$MISSING"
        if [ "${SKIP_PACKAGES:-no}" != "yes" ] && ask "Install them now?"; then
            # shellcheck disable=SC2086
            sudo pacman -S --needed --noconfirm $MISSING || \
                warn "Some packages failed to install"
        fi
    fi

    # layer-shell integration — without it the greeter starts, logs nothing
    # unusual, and renders an empty screen (mouse cursor visible only).
    if ! pacman -Qq "$LAYER_PKG" &>/dev/null; then
        warn "Missing $LAYER_PKG — without it the login screen renders blank."
        if pacman -Si "$LAYER_PKG" &>/dev/null; then
            [ "${SKIP_PACKAGES:-no}" != "yes" ] && ask "Install $LAYER_PKG?" && \
                sudo pacman -S --needed --noconfirm "$LAYER_PKG"
        else
            AURHELPER=""
            command -v yay  &>/dev/null && AURHELPER="yay"
            command -v paru &>/dev/null && AURHELPER="paru"
            if [ -n "$AURHELPER" ]; then
                ask "Install $LAYER_PKG from AUR?" && \
                    $AURHELPER -S --needed --noconfirm "$LAYER_PKG"
            else
                error "$LAYER_PKG is AUR-only and no AUR helper is installed."
                error "Install it manually or the login screen will be blank:"
                error "  paru -S $LAYER_PKG"
            fi
        fi
    fi

    # Fonts the theme names must exist or text falls back to a default
    if [ -f "$S/missing-fonts.txt" ]; then
        while IFS= read -r fam; do
            [ -z "$fam" ] && continue
            fc-list : family 2>/dev/null | tr ',' '\n' | grep -qixF "$fam" || \
                warn "Theme font '$fam' is not installed — text may look wrong"
        done < "$S/missing-fonts.txt"
    fi

    # ── 4. Set the theme ─────────────────────────────────────────────────────
    sudo mkdir -p /etc/sddm.conf.d
    printf '[Theme]\nCurrent=%s\n' "$THEME_NAME" | \
        sudo tee /etc/sddm.conf.d/10-theme.conf >/dev/null
    [ -d "$S/sddm.conf.d" ] && \
        sudo cp -a "$S/sddm.conf.d/." /etc/sddm.conf.d/ 2>/dev/null

    # ── 5. Actually render it before trusting it ─────────────────────────────
    # The greeter prints "Fallback to embedded theme" when it cannot load the
    # theme. That string is the reliable signal — the exit code is not.
    THEME_OK=unknown
    if command -v "$GREETER" &>/dev/null; then
        info "Testing the login theme with $GREETER..."
        TESTLOG=$(mktemp)
        timeout 15 "$GREETER" --test-mode \
            --theme "/usr/share/sddm/themes/$THEME_NAME" >"$TESTLOG" 2>&1
        if grep -q "No shell integration named" "$TESTLOG"; then
            THEME_OK=no
            error "layer-shell integration missing — the greeter would render blank."
            error "Install $LAYER_PKG and re-run."
        elif grep -q "no Qt platform plugin could be initialized" "$TESTLOG"; then
            THEME_OK=no
            error "Wayland platform plugin missing — the greeter would crash."
            error "Install qt5-wayland / qt6-wayland and re-run."
        elif grep -q "Fallback to embedded theme" "$TESTLOG"; then
            THEME_OK=no
            error "Theme failed to load. Missing QML modules:"
            grep -oP 'module "\K[^"]+(?=" is not installed)' "$TESTLOG" | \
                sort -u | sed 's/^/      /'
            grep -oP 'No such file or directory' "$TESTLOG" | head -1 | \
                sed 's/^/      missing file: /'
        else
            THEME_OK=yes
            success "Login theme renders correctly"
        fi
        cp "$TESTLOG" "$HOME/kde-restore-sddm-test.log" 2>/dev/null
        rm -f "$TESTLOG"
    else
        warn "$GREETER not found — cannot verify the theme"
    fi

    # ── 6. Only switch the login manager if the theme is proven good ─────────
    if [ "$THEME_OK" = "no" ]; then
        error "Reverting to the Breeze login theme so you can still log in."
        printf '[Theme]\nCurrent=breeze\n' | \
            sudo tee /etc/sddm.conf.d/10-theme.conf >/dev/null
        warn "Full test output: ~/kde-restore-sddm-test.log"
        warn "Login manager left as '$CURRENT_DM' — nothing was switched."
    elif [ "$THEME_OK" != "yes" ]; then
        warn "Could not verify the theme. Not switching login manager."
    else
        if ! pacman -Qq sddm &>/dev/null; then
            warn "SDDM is not installed. Plasma Login Manager cannot show QML themes."
            if ask "Install SDDM and switch to it?"; then
                sudo pacman -S --needed --noconfirm sddm sddm-kcm && \
                    sudo systemctl enable --force sddm.service && \
                    success "SDDM installed and enabled"
            fi
        elif [ -n "$CURRENT_DM" ] && [ "$CURRENT_DM" != "sddm.service" ]; then
            echo ""
            warn "Your login manager is '$CURRENT_DM', not SDDM."
            warn "Custom login themes only work on SDDM."
            info "If the login screen ever goes black: Ctrl+Alt+F3, then"
            info "  sudo systemctl enable --force $CURRENT_DM && sudo reboot"
            echo ""
            if ask "Switch the login manager to SDDM?" "n"; then
                printf 'Previous display manager: %s\n\nTo revert:\n  sudo systemctl enable --force %s\n  sudo reboot\n' \
                    "$CURRENT_DM" "$CURRENT_DM" > "$HOME/RESTORE-UNDO-LOGIN.txt"
                sudo systemctl enable --force sddm.service && \
                    success "Switched to SDDM (takes effect on reboot)"
                warn "Undo instructions: ~/RESTORE-UNDO-LOGIN.txt"
            else
                info "Login manager unchanged — theme is ready if you switch later."
            fi
        else
            success "Already on SDDM with a working theme"
        fi
    fi

    fi  # end: theme exists

    [ -d "$S/user-sddm" ] && safe_restore_dir "$S/user-sddm" "$HOME/.local/share/sddm"
fi

# =============================================================================
header "Step 7 · Widgets & KWin effects"
# =============================================================================
if [ -d "$IN/widgets" ] && ask "Restore widgets and KWin effects?"; then
    W="$IN/widgets"
    if [ -d "$W/files" ]; then
        mkdir -p "$HOME/.local/share/plasma/plasmoids"
        for d in "$W/files"/*/; do
            [ -d "$d" ] || continue
            cp -a "$d" "$HOME/.local/share/plasma/plasmoids/$(basename "$d")" && \
                success "Widget: $(basename "$d")"
        done
    fi
    safe_restore_dir "$W/kwin-scripts" "$HOME/.local/share/kwin/scripts"
    safe_restore_dir "$W/kwin-effects" "$HOME/.local/share/kwin/effects"

    if [ -s "$W/plasmoids.packages" ]; then
        info "Widgets provided by packages (installed in step 1):"
        sed 's/^/    /' "$W/plasmoids.packages"
    fi
fi

# =============================================================================
header "Step 7b · Extra customization (shells, launchers, scripts)"
# =============================================================================
if [ -d "$IN/extras" ] && ask "Restore extra customization (rice tooling, scripts)?"; then
    EX="$IN/extras"

    if [ -d "$EX/config" ]; then
        for d in "$EX/config"/*; do
            [ -e "$d" ] || continue
            safe_restore "$d" "$HOME/.config/$(basename "$d")"
        done
    fi

    if [ -d "$EX/local-share" ]; then
        for d in "$EX/local-share"/*; do
            [ -e "$d" ] || continue
            safe_restore "$d" "$HOME/.local/share/$(basename "$d")"
        done
    fi

    if [ -d "$EX/bin" ] && [ -n "$(ls -A "$EX/bin" 2>/dev/null)" ]; then
        mkdir -p "$HOME/.local/bin"
        cp -a "$EX/bin/." "$HOME/.local/bin/" && \
            chmod +x "$HOME"/.local/bin/* 2>/dev/null
        success "User scripts restored to ~/.local/bin"
        case ":$PATH:" in
            *":$HOME/.local/bin:"*) ;;
            *) warn "~/.local/bin is not in your PATH — some scripts won't run" ;;
        esac
    fi

    if [ -d "$EX/systemd-user" ] && [ -n "$(ls -A "$EX/systemd-user" 2>/dev/null)" ]; then
        mkdir -p "$HOME/.config/systemd/user"
        cp -a "$EX/systemd-user/." "$HOME/.config/systemd/user/"
        systemctl --user daemon-reload 2>/dev/null
        success "Theming services installed"
        for unit in "$EX/systemd-user"/*.service; do
            [ -f "$unit" ] || continue
            u=$(basename "$unit")
            ask "  Enable and start $u?" && \
                systemctl --user enable --now "$u" 2>/dev/null && \
                success "  $u running"
        done
    fi

    if [ -d "$EX/manual" ]; then
        info "Paths included manually by the pack author:"
        [ -f "$EX/manual/ORIGINAL-PATHS.txt" ] && \
            sed 's/^/    /' "$EX/manual/ORIGINAL-PATHS.txt"
        warn "These were not auto-placed — copy them where they belong:"
        info "    $EX/manual/"
    fi
fi

# =============================================================================
header "Step 7c · Components needing their own installer"
# =============================================================================
if [ -f "$IN/EXTERNAL-SETUPS.txt" ]; then
    echo ""
    warn "This pack contains parts that CANNOT be restored by copying files."
    warn "They come from projects with their own installers."
    echo ""
    sed 's/^/    /' "$IN/EXTERNAL-SETUPS.txt"
    echo ""
    cp "$IN/EXTERNAL-SETUPS.txt" "$HOME/kde-restore-external-setups.txt" 2>/dev/null
    warn "Saved to ~/kde-restore-external-setups.txt"
    info "Config files for these ARE in extras/ and were restored above —"
    info "install the software itself, then everything should line up."
    echo ""
    ask "Understood, continue?" || { info "Stopped."; exit 0; }
else
    success "No externally-installed components in this pack"
fi

# =============================================================================
header "Step 8 · GTK"
# =============================================================================
if [ -d "$IN/gtk" ] && ask "Restore GTK theme settings?"; then
    safe_restore     "$IN/gtk/gtk-3.0"   "$HOME/.config/gtk-3.0"
    safe_restore     "$IN/gtk/gtk-4.0"   "$HOME/.config/gtk-4.0"
    safe_restore     "$IN/gtk/gtkrc-2.0" "$HOME/.gtkrc-2.0"
    safe_restore_dir "$IN/gtk/themes"    "$HOME/.local/share/themes"
fi

# =============================================================================
header "Step 9 · Wallpapers"
# =============================================================================
if [ -d "$IN/wallpapers" ] && ask "Restore wallpapers?"; then
    [ -d "$IN/wallpapers/Pictures" ] && \
        safe_restore_dir "$IN/wallpapers/Pictures" "$HOME/Pictures"
    [ -d "$IN/wallpapers/local-wallpapers" ] && \
        safe_restore_dir "$IN/wallpapers/local-wallpapers" "$HOME/.local/share/wallpapers"
    mkdir -p "$HOME/Pictures/Wallpapers"
    for f in "$IN/wallpapers"/*.*; do
        [ -f "$f" ] || continue
        # images only — in-use.txt and other bookkeeping files stay in the pack
        case "${f,,}" in
            *.jpg|*.jpeg|*.png|*.webp|*.gif|*.mp4|*.webm) ;;
            *) continue ;;
        esac
        cp -a "$f" "$HOME/Pictures/Wallpapers/" 2>/dev/null
    done
    success "Wallpapers restored"
fi

# =============================================================================
header "Step 9b · Rice tooling & extra paths"
# =============================================================================
if [ -d "$IN/extras" ]; then
    HAS_EXTRAS=0
    for sub in config local-share bin systemd-user manual; do
        [ -d "$IN/extras/$sub" ] && [ -n "$(ls -A "$IN/extras/$sub" 2>/dev/null)" ] && HAS_EXTRAS=1
    done

    if [ "$HAS_EXTRAS" = "1" ]; then
        echo ""
        info "This pack includes extra tooling:"
        for sub in config local-share bin; do
            [ -d "$IN/extras/$sub" ] || continue
            ls -1 "$IN/extras/$sub" 2>/dev/null | sed "s|^|    $sub/|"
        done
        echo ""
        if ask "Restore these?"; then
            for d in "$IN/extras/config"/*; do
                [ -e "$d" ] || continue
                safe_restore "$d" "$HOME/.config/$(basename "$d")"
            done
            for d in "$IN/extras/local-share"/*; do
                [ -e "$d" ] || continue
                safe_restore "$d" "$HOME/.local/share/$(basename "$d")"
            done
            if [ -d "$IN/extras/bin" ] && [ -n "$(ls -A "$IN/extras/bin" 2>/dev/null)" ]; then
                mkdir -p "$HOME/.local/bin"
                cp -a "$IN/extras/bin/." "$HOME/.local/bin/" && \
                    chmod +x "$HOME/.local/bin"/* 2>/dev/null
                success "Scripts restored to ~/.local/bin"
                case ":$PATH:" in
                    *":$HOME/.local/bin:"*) ;;
                    *) warn "~/.local/bin is not on your PATH — add it in your shell config" ;;
                esac
            fi
            if [ -d "$IN/extras/systemd-user" ]; then
                mkdir -p "$HOME/.config/systemd/user"
                cp -a "$IN/extras/systemd-user/." "$HOME/.config/systemd/user/" 2>/dev/null
                systemctl --user daemon-reload 2>/dev/null
                info "User services copied — enable them with:"
                ls -1 "$IN/extras/systemd-user" 2>/dev/null | \
                    sed 's|^|    systemctl --user enable --now |'
            fi
            if [ -d "$IN/extras/manual" ]; then
                warn "Manually-included paths need placing by hand:"
                [ -f "$IN/extras/manual/ORIGINAL-PATHS.txt" ] && \
                    sed 's|^|    |' "$IN/extras/manual/ORIGINAL-PATHS.txt"
                info "They are in: $IN/extras/manual/"
            fi
            success "Extras restored"
        fi
    fi
fi

# =============================================================================
header "Step 10 · Spicetify"
# =============================================================================
if [ -d "$IN/spicetify" ] && ask "Restore Spicetify theme?"; then
    mkdir -p "$HOME/.config/spicetify"
    safe_restore_dir "$IN/spicetify/Themes"     "$HOME/.config/spicetify/Themes"
    safe_restore_dir "$IN/spicetify/Extensions" "$HOME/.config/spicetify/Extensions"
    info "Run 'spicetify backup apply' once Spotify is installed"
fi

# =============================================================================
#  MIGRATE-ONLY SECTIONS
# =============================================================================
if [ "$TYPE" = "migrate" ]; then

    header "Step 11 · App configs & dotfiles"
    if [ -d "$IN/apps" ] && ask "Restore app configs and shell dotfiles?"; then
        for d in "$IN/apps/config"/*; do
            [ -e "$d" ] || continue
            safe_restore "$d" "$HOME/.config/$(basename "$d")"
        done
        shopt -s dotglob nullglob
        for f in "$IN/apps/home"/*; do
            [ -f "$f" ] || continue
            safe_restore "$f" "$HOME/$(basename "$f")"
        done
        shopt -u dotglob nullglob
        safe_restore_dir "$IN/apps/local/bin"  "$HOME/.local/bin"
        safe_restore_dir "$IN/apps/local/mime" "$HOME/.local/share/mime"
        skipmsg ".desktop files — auto-created by package installs"
    fi

    # App data chosen in HermitCrab (settings, data — caches only if ticked)
    if [ -d "$IN/apps/extra/home" ] && ask "Restore app data (settings of your installed apps)?"; then
        cp -a "$IN/apps/extra/home/." "$HOME/" && success "App data restored" || \
            warn "Some app data could not be restored"
    fi

    header "Step 12 · Browsers"
    if [ -d "$IN/browsers" ] && ask "Restore browser profiles?"; then
        B="$IN/browsers"
        if [ -d "$B/brave" ]; then
            D="$HOME/.config/BraveSoftware/Brave-Browser"; mkdir -p "$D"
            [ -f "$B/brave/Local State" ] && safe_restore "$B/brave/Local State" "$D/Local State"
            for p in "$B/brave"/*/; do
                [ -d "$p" ] && safe_restore_dir "$p" "$D/$(basename "$p")"
            done
        fi
        for pair in "zen:$HOME/.zen" "firefox:$HOME/.mozilla/firefox"; do
            n="${pair%%:*}"; dest="${pair#*:}"
            [ -d "$B/$n" ] || continue
            mkdir -p "$dest"
            [ -f "$B/$n/profiles.ini" ] && safe_restore "$B/$n/profiles.ini" "$dest/profiles.ini"
            [ -f "$B/$n/installs.ini" ] && safe_restore "$B/$n/installs.ini" "$dest/installs.ini"
            for p in "$B/$n"/*/; do
                [ -d "$p" ] && safe_restore_dir "$p" "$dest/$(basename "$p")"
            done
        done
        warn "Saved passwords were not backed up — sign in again"
    fi

    header "Step 13 · Network & power"
    if [ -d "$IN/network/nm-connections" ] && ask "Restore WiFi/VPN connections? (sudo)"; then
        sudo cp -a "$IN/network/nm-connections/." /etc/NetworkManager/system-connections/
        sudo chown -R root:root /etc/NetworkManager/system-connections/
        sudo chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null
        sudo systemctl restart NetworkManager 2>/dev/null
        success "Network connections restored"
    fi
    if [ -f "$IN/network/tlp.conf" ] && ask "Restore power config?"; then
        sudo cp "$IN/network/tlp.conf" /etc/tlp.conf 2>/dev/null
        [ -f "$IN/network/auto-cpufreq.conf" ] && \
            sudo cp "$IN/network/auto-cpufreq.conf" /etc/auto-cpufreq.conf 2>/dev/null
        success "Power config restored"
    fi

    header "Step 14 · SSH & GPG"
    if [ -d "$IN/keys" ]; then
        if [ -d "$IN/keys/ssh" ] && ask "Restore SSH keys? (trusted machine only)" "n"; then
            cp -a "$IN/keys/ssh" "$HOME/.ssh"
            chmod 700 "$HOME/.ssh"
            find "$HOME/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null
            success "SSH keys restored"
        fi
        if ask "Import GPG keys? (trusted machine only)" "n"; then
            [ -f "$IN/keys/gpg-public.asc"  ] && gpg --import "$IN/keys/gpg-public.asc"  2>/dev/null
            [ -f "$IN/keys/gpg-private.asc" ] && gpg --import "$IN/keys/gpg-private.asc" 2>/dev/null
            [ -f "$IN/keys/gpg-ownertrust.txt" ] && \
                gpg --import-ownertrust "$IN/keys/gpg-ownertrust.txt" 2>/dev/null
            success "GPG keys imported"
        fi
    fi

    header "Step 15 · Misc"
    if [ -d "$IN/misc" ] && ask "Restore systemd user units and crontab?"; then
        safe_restore_dir "$IN/misc/systemd-user"  "$HOME/.config/systemd"
        safe_restore     "$IN/misc/environment.d" "$HOME/.config/environment.d"
        systemctl --user daemon-reload 2>/dev/null
        [ -s "$IN/misc/crontab.txt" ] && crontab "$IN/misc/crontab.txt" && \
            success "Crontab restored"
    fi
fi

# =============================================================================
header "Applying theme selections"
# =============================================================================
# ORDER MATTERS. plasma-apply-lookandfeel REWRITES kdeglobals and kcminputrc,
# wiping Theme= and cursorTheme=. So the global theme is applied FIRST, and the
# individual settings are written afterwards with kwriteconfig6 so they stick.

if [ -f "$IN/ACTIVE-THEME" ]; then
    sed 's/^/    /' "$IN/ACTIVE-THEME"
    echo ""

    get_active() { grep -m1 "^$1=" "$IN/ACTIVE-THEME" | cut -d= -f2-; }
    LNF=$(get_active lookAndFeel)
    CS=$(get_active colorScheme)
    ICONS=$(get_active iconTheme)
    CURSOR=$(get_active cursorTheme)
    CSIZE=$(get_active cursorSize)
    SPLASH=$(get_active splash)
    PTHEME=$(get_active plasmaTheme)

    KW=kwriteconfig6; command -v kwriteconfig6 &>/dev/null || KW=kwriteconfig5

    # 1) Global theme FIRST (it overwrites other keys)
    if [ -n "$LNF" ] && command -v plasma-apply-lookandfeel &>/dev/null; then
        plasma-apply-lookandfeel -a "$LNF" &>/dev/null && \
            success "Global theme: $LNF" || \
            warn "Could not apply global theme automatically"
        sleep 1
    fi

    # 2) Then every individual setting, so nothing is left at a default
    if [ -n "$CS" ] && command -v plasma-apply-colorscheme &>/dev/null; then
        plasma-apply-colorscheme "$CS" &>/dev/null && success "Color scheme: $CS"
    fi

    if [ -n "$ICONS" ]; then
        $KW --file kdeglobals --group Icons --key Theme "$ICONS"
        success "Icon theme: $ICONS"
    fi

    if [ -n "$PTHEME" ]; then
        $KW --file plasmarc --group Theme --key name "$PTHEME"
        success "Plasma style: $PTHEME"
    fi

    if [ -n "$SPLASH" ]; then
        $KW --file ksplashrc --group KSplash --key Theme "$SPLASH"
        $KW --file ksplashrc --group KSplash --key Engine KSplashQML
        success "Splash screen: $SPLASH"
    fi

    if [ -n "$CURSOR" ]; then
        $KW --file kcminputrc --group Mouse --key cursorTheme "$CURSOR"
        [ -n "$CSIZE" ] && $KW --file kcminputrc --group Mouse --key cursorSize "$CSIZE"
        # X11/GTK apps read this instead of kcminputrc
        mkdir -p "$HOME/.icons/default"
        printf '[Icon Theme]\nInherits=%s\n' "$CURSOR" > "$HOME/.icons/default/index.theme"
        # Live-apply on Wayland where supported
        command -v plasma-apply-cursortheme &>/dev/null && \
            plasma-apply-cursortheme "$CURSOR" --size "${CSIZE:-24}" &>/dev/null
        success "Cursor: $CURSOR (size ${CSIZE:-24})"
    fi

    # 3) Verify the settings actually landed
    echo ""
    info "Verifying applied settings:"
    verify() {
        local label="$1" want="$2" got="$3"
        if [ -z "$want" ]; then return; fi
        if [ "$want" = "$got" ]; then
            success "  $label = $got"
        else
            warn "  $label: wanted '$want', got '${got:-unset}'"
        fi
    }
    verify "icon theme"   "$ICONS"  "$(grep -m1 '^Theme='       "$HOME/.config/kdeglobals" 2>/dev/null | cut -d= -f2-)"
    verify "color scheme" "$CS"     "$(grep -m1 '^ColorScheme=' "$HOME/.config/kdeglobals" 2>/dev/null | cut -d= -f2-)"
    verify "cursor"       "$CURSOR" "$(grep -m1 '^cursorTheme=' "$HOME/.config/kcminputrc" 2>/dev/null | cut -d= -f2-)"
    verify "splash"       "$SPLASH" "$(grep -m1 '^Theme='       "$HOME/.config/ksplashrc"  2>/dev/null | cut -d= -f2-)"
fi

# ── Re-enable KWin effects ───────────────────────────────────────────────────
# This is why rounded corners (ShapeCorners) and other effects went missing:
# the effect flags live in kwinrc under [Plugins], and applying a global theme
# rewrites kwinrc — wiping them. Copying kwinrc earlier is not enough; the
# flags have to be written back AFTER the theme is applied.
KWIN_STATE=""
for cand in "$IN/widgets/kwin-effects-state" "$IN/widgets/kwin-enabled.txt"; do
    [ -f "$cand" ] && { KWIN_STATE="$cand"; break; }
done

if [ -n "$KWIN_STATE" ]; then
    info "Re-enabling KWin effects..."
    restore_kwin_effects "$KWIN_STATE"

    ENABLED_COUNT=$(grep -c 'Enabled=true' "$KWIN_STATE" 2>/dev/null || echo 0)
    success "Restored $ENABLED_COUNT effect settings"

    # Warn about effects that are switched on but whose plugin is absent —
    # ShapeCorners is the usual offender since it is a compiled AUR package.
    while IFS='=' read -r key val; do
        [ "$val" = "true" ] || continue
        eff="${key%Enabled}"
        [ -z "$eff" ] && continue
        # Built-in effects live in the kwin package; third-party ones don't
        if ! find /usr/lib/qt6/plugins/kwin/effects/plugins \
                  /usr/lib/qt/plugins/kwin/effects/plugins \
                  "$HOME/.local/share/kwin/effects" \
                  -iname "*${eff}*" 2>/dev/null | grep -q .; then
            case "$eff" in
                blur|contrast|slide|magiclamp|wobblywindows|translucency|\
                cube|magnifier|mousemark|zoom|screenshot|overview|windowview|\
                desktopgrid|dimscreen|fallapart|glide|login|logout|scale|\
                sheet|slidingpopups|squash|startupfeedback|kscreen) ;;
                *)
                    warn "Effect '$eff' is enabled but its plugin is not installed"
                    echo "$eff" >> "$HOME/kde-restore-missing-effects.txt" ;;
            esac
        fi
    done < "$KWIN_STATE"

    if [ -f "$HOME/kde-restore-missing-effects.txt" ]; then
        echo ""
        warn "Some enabled effects have no plugin installed. Common ones:"
        info "  ShapeCorners (rounded corners):  paru -S kwin-effect-rounded-corners"
        info "  ForceBlur:                       paru -S kwin-effects-forceblur"
        warn "List saved to ~/kde-restore-missing-effects.txt"
    fi
fi

# Restart plasmashell now that all configs are written
start_plasmashell

# Reload KWin so window decorations and effects take effect without a logout
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    qdbus6 org.kde.KWin /KWin reconfigure &>/dev/null || \
        qdbus org.kde.KWin /KWin reconfigure &>/dev/null || true
else
    (setsid kwin_x11 --replace &>/dev/null &) 
fi

info "Rebuilding caches..."
kbuildsycoca6 --noincremental &>/dev/null || kbuildsycoca5 --noincremental &>/dev/null
update-desktop-database "$HOME/.local/share/applications" &>/dev/null
fc-cache -f &>/dev/null

$CLEANUP && rm -rf "$TMP"

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          RESTORE COMPLETE              ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Now do this:${NC}"
echo    "   1.  Log out and back in (a reboot is safest)"
echo    "   2.  System Settings → Appearance → confirm theme is selected"
echo    "   3.  System Settings → Desktop Effects → enable the effects you want"
echo    "   4.  If the panel is wrong: right-click desktop → Enter Edit Mode"
if [ "$TYPE" = "themepack" ]; then
echo    "   5.  Spicetify users: spicetify backup apply"
fi
echo ""
echo -e "  Log: ${CYAN}$LOG${NC}"
echo ""
