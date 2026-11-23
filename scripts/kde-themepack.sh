#!/usr/bin/env bash
# =============================================================================
#  kde-themepack.sh — Shareable KDE Plasma 6 theme pack (CachyOS / Arch)
#
#  Exports ONLY visual customization + the exact packages needed to run it.
#  Refuses to build the archive if anything sensitive is detected.
#
#  Usage:
#    ./kde-themepack.sh                     # → ~/kde-themepack-DATE/
#    ./kde-themepack.sh /mnt/drive          # → timestamped folder inside
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kde-lib.sh
source "$SCRIPT_DIR/kde-lib.sh" || { echo "kde-lib.sh not found next to this script"; exit 1; }

trap cleanup_owner_cache EXIT

# ── Arguments ────────────────────────────────────────────────────────────────
# Usage: ./kde-themepack.sh [dest] [--include PATH]... [--no-sweep]
DEST_ARG=""
EXTRA_INCLUDES=()
DO_SWEEP=yes
while [ $# -gt 0 ]; do
    case "$1" in
        --include) EXTRA_INCLUDES+=("$2"); shift 2 ;;
        --no-sweep) DO_SWEEP=no; shift ;;
        -h|--help)
            echo "Usage: $0 [destination] [--include PATH]... [--no-sweep]"
            echo "  --include PATH   also ship this file or directory"
            echo "  --no-sweep       skip scanning for unrecognised config dirs"
            exit 0 ;;
        *) [ -z "$DEST_ARG" ] && DEST_ARG="$1"; shift ;;
    esac
done

OUT="$(resolve_dest "$DEST_ARG" "kde-themepack")"
ARCHIVE="${OUT}.tar.gz"
mkdir -p "$OUT"
LOG="$OUT/export.log"
exec > >(tee -a "$LOG") 2>&1

echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  ┌───────────────────────────────────────────────┐
  │   K D E   T H E M E P A C K   ·   shareable   │
  └───────────────────────────────────────────────┘
BANNER
echo -e "${NC}"
echo "  Destination : $OUT"
echo "  Started     : $(date)"
echo ""
echo -e "  ${GREEN}✓  Visual customization only — no keys, passwords, or history${NC}"

build_owner_cache

# =============================================================================
header "0 · Checking what kind of setup this is"
# =============================================================================
TIER3="$OUT/TIER3-REPORT"
if detect_tier3 "$TIER3"; then
    echo ""
    warn "This system uses components that a theme pack CANNOT reproduce:"
    echo ""
    while IFS='|' read -r kind item note; do
        printf "    %-6s %-32s %s\n" "[$kind]" "$item" "$note"
    done < "$TIER3"
    echo ""
    warn "Setups like this ship their own installer. Copying config files"
    warn "will produce a broken result — the widgets simply will not start."
    echo ""
    info "The pack will still be built, and will correctly carry your Plasma"
    info "themes, colours, icons, cursors, fonts and SDDM theme."
    info "Whoever installs it should run the upstream installer FIRST,"
    info "then apply this pack on top for your personal tweaks."
    echo ""
    if ! ask "Continue building the pack anyway?"; then
        info "Aborted."
        rm -rf "$OUT"
        exit 0
    fi
else
    success "Standard Plasma customization — fully reproducible"
    rm -f "$TIER3"
fi

# Accumulates packages the recipient will need
DEPS="$OUT/dependencies"; mkdir -p "$DEPS"
: > "$DEPS/native.txt"
: > "$DEPS/aur.txt"

add_pkg() {
    local p="$1"
    [ -z "$p" ] && return
    if pacman -Qqm 2>/dev/null | grep -qx "$p"; then
        echo "$p" >> "$DEPS/aur.txt"
    else
        echo "$p" >> "$DEPS/native.txt"
    fi
}

# =============================================================================
header "1 · Appearance settings"
# =============================================================================
C="$OUT/config"; mkdir -p "$C"

# Only visual keys — no shortcuts, no wallet, no device pairings
for cfg in \
    plasmarc plasma-org.kde.plasma.desktop-appletsrc plasmashellrc \
    kwinrc kdeglobals kcminputrc ksplashrc kscreenlockerrc breezerc; do
    safe_copy "$HOME/.config/$cfg" "$C/$cfg"
done

safe_copy_dir "$HOME/.config/Kvantum"          "$C/Kvantum"
safe_copy_dir "$HOME/.config/plasma-workspace" "$C/plasma-workspace"
safe_copy_dir "$HOME/.local/share/konsole"     "$C/konsole"

skipmsg "kglobalshortcutsrc — personal key bindings"
skipmsg "kwalletrc, kdeconnect — private"

# Record the active selections explicitly so restore can re-apply them
{
    echo "lookAndFeel=$(grep -m1 '^LookAndFeelPackage=' "$HOME/.config/kdeglobals" 2>/dev/null | cut -d= -f2-)"
    echo "colorScheme=$(grep  -m1 '^ColorScheme='        "$HOME/.config/kdeglobals" 2>/dev/null | cut -d= -f2-)"
    echo "iconTheme=$(grep    -m1 '^Theme='              "$HOME/.config/kdeglobals" 2>/dev/null | cut -d= -f2-)"
    echo "plasmaTheme=$(grep  -m1 '^name='               "$HOME/.config/plasmarc"   2>/dev/null | cut -d= -f2-)"
    echo "cursorTheme=$(grep  -m1 '^cursorTheme='        "$HOME/.config/kcminputrc" 2>/dev/null | cut -d= -f2-)"
    echo "cursorSize=$(grep   -m1 '^cursorSize='         "$HOME/.config/kcminputrc" 2>/dev/null | cut -d= -f2-)"
    echo "splash=$(grep       -m1 '^Theme='              "$HOME/.config/ksplashrc"  2>/dev/null | cut -d= -f2-)"
    echo "sddmTheme=$(grep -rhoP '(?<=^Current=).*' /etc/sddm.conf.d/ /etc/sddm.conf 2>/dev/null | head -1)"
} > "$OUT/ACTIVE-THEME"
success "Active theme selections recorded"
cat "$OUT/ACTIVE-THEME" | sed 's/^/    /'

# =============================================================================
header "2 · Themes"
# =============================================================================
T="$OUT/themes"; mkdir -p "$T"

safe_copy_dir "$HOME/.local/share/plasma/desktoptheme"  "$T/desktoptheme"
safe_copy_dir "$HOME/.local/share/plasma/look-and-feel" "$T/look-and-feel"
safe_copy_dir "$HOME/.local/share/color-schemes"        "$T/color-schemes"
safe_copy_dir "$HOME/.local/share/aurorae"              "$T/aurorae"
safe_copy_dir "$HOME/.local/share/kstyle"               "$T/kstyle"
safe_copy_dir "$HOME/.local/share/Kvantum"              "$T/Kvantum"

# System themes: ship if unowned, list as package if owned
mkdir -p "$T/system-unowned"
for base in /usr/share/plasma/desktoptheme /usr/share/plasma/look-and-feel \
            /usr/share/aurorae/themes /usr/share/color-schemes /usr/share/Kvantum; do
    [ -d "$base" ] || continue
    for d in "$base"/*/; do
        [ -d "$d" ] || continue
        own=$(owner_of "$d")
        if [ -n "$own" ]; then
            add_pkg "$own"
        else
            rel="${d#/usr/share/}"
            mkdir -p "$T/system-unowned/$(dirname "$rel")"
            kp_cp "$d" "$T/system-unowned/$rel" 2>/dev/null && \
                success "Shipping unowned: $rel"
        fi
    done
done

# =============================================================================
header "3 · Icons & cursors"
# =============================================================================
I="$OUT/icons"; mkdir -p "$I"
safe_copy_dir "$HOME/.local/share/icons" "$I/local-icons"
safe_copy_dir "$HOME/.icons"             "$I/dot-icons"

mkdir -p "$I/system-unowned"
for d in /usr/share/icons/*/; do
    [ -d "$d" ] || continue
    own=$(owner_of "$d")
    if [ -n "$own" ]; then
        # Only add as a dependency if it's the cursor/icon theme actually in use
        tn=$(basename "$d")
        if grep -qx "cursorTheme=$tn" "$OUT/ACTIVE-THEME" 2>/dev/null || \
           grep -qx "iconTheme=$tn"   "$OUT/ACTIVE-THEME" 2>/dev/null; then
            add_pkg "$own"
        fi
    else
        kp_cp "$d" "$I/system-unowned/$(basename "$d")" 2>/dev/null && \
            success "Shipping unowned icon/cursor: $(basename "$d")"
    fi
done

safe_copy "$HOME/.icons/default" "$I/x11-default"

# =============================================================================
header "4 · Fonts"
# =============================================================================
F="$OUT/fonts"; mkdir -p "$F"
safe_copy_dir "$HOME/.local/share/fonts" "$F/local-fonts"
safe_copy_dir "$HOME/.fonts"             "$F/dot-fonts"
safe_copy_dir "$HOME/.config/fontconfig" "$F/fontconfig"

# Fonts referenced in kdeglobals → find owning packages
grep -hoP '^(font|fixed|menuFont|toolBarFont|smallestReadableFont|activeFont)=\K[^,]+' \
    "$HOME/.config/kdeglobals" 2>/dev/null | sort -u > "$F/required-families.txt"

while read -r fam; do
    [ -z "$fam" ] && continue
    # Verify the family actually exists before trusting fc-match, which
    # silently falls back to a default font for unknown families.
    if ! fc-list : family 2>/dev/null | tr ',' '\n' | grep -qixF "$fam"; then
        warn "Font '$fam' is not installed here — recipient may see a fallback"
        continue
    fi
    fpath=$(fc-match -f '%{file}' "$fam" 2>/dev/null)
    [ -z "$fpath" ] && continue
    own=$(owner_of_file "$fpath")
    if [ -n "$own" ]; then
        add_pkg "$own"
        success "Font '$fam' → $own"
    else
        warn "Font '$fam' is not from a package — shipping the file"
        mkdir -p "$F/shipped"
        kp_cp "$fpath" "$F/shipped/" 2>/dev/null
    fi
done < "$F/required-families.txt"

# =============================================================================
header "5 · SDDM theme"
# =============================================================================
S="$OUT/sddm"; mkdir -p "$S/themes"
safe_copy_dir /etc/sddm.conf.d "$S/sddm.conf.d"
safe_copy     /etc/sddm.conf   "$S/sddm.conf"

ACTIVE_SDDM=$(grep -m1 '^sddmTheme=' "$OUT/ACTIVE-THEME" | cut -d= -f2-)
for d in /usr/share/sddm/themes/*/; do
    [ -d "$d" ] || continue
    tname=$(basename "$d")
    own=$(owner_of "$d")
    if [ -z "$own" ]; then
        # Unowned = yours. Ship it.
        kp_cp "$d" "$S/themes/$tname" 2>/dev/null && \
            success "SDDM theme shipped: $tname ($(du -sh "$d" | cut -f1))"

        # Detect whether this theme is Qt5 or Qt6 and record it.
        # Loading a Qt5 theme with the Qt6 greeter (or vice versa) makes SDDM
        # fall back to the embedded theme = BLACK SCREEN at login.
        tqt=$(detect_qt_version "$S/themes/$tname")
        echo "$tname=$tqt" >> "$S/theme-qt-versions"
        info "  $tname is a Qt$tqt theme"

        meta="$S/themes/$tname/metadata.desktop"
        if [ -f "$meta" ]; then
            sed -i '/^QtVersion=/d' "$meta"
            # Only Qt6 needs the explicit key; omitting it selects the Qt5 greeter
            if [ "$tqt" = "6" ]; then
                echo "QtVersion=6" >> "$meta"
                info "  set QtVersion=6"
            else
                info "  left unversioned (Qt5 greeter)"
            fi
        fi

        # Pull in the matching Qt runtime for this theme.
        #
        # IMPORTANT: three classes of dependency are INVISIBLE to QML import
        # scanning, and each one produces a black login screen with no error:
        #   1. Platform plugin   (qt5-wayland)      — greeter aborts at startup
        #   2. Shell integration (layer-shell-qt5)  — greeter runs but draws
        #                                             nothing; only the cursor
        #                                             is visible
        #   3. Media codecs      (gst-libav etc.)   — video backgrounds render
        #                                             as solid black
        # They are added unconditionally for that reason.
        if [ "$tqt" = "5" ]; then
            for qp in qt5-declarative qt5-graphicaleffects qt5-quickcontrols2 \
                      qt5-quickcontrols qt5-svg qt5-multimedia qt5-base \
                      qt5-translations qt5-wayland; do
                pacman -Si "$qp" &>/dev/null && add_pkg "$qp"
            done
            # layer-shell for Qt5 is AUR-only on most Arch derivatives
            if pacman -Si layer-shell-qt5 &>/dev/null; then
                add_pkg "layer-shell-qt5"
            elif pacman -Qq layer-shell-qt5 &>/dev/null; then
                echo "layer-shell-qt5" >> "$DEPS/aur.txt"
            else
                echo "layer-shell-qt5" >> "$DEPS/aur.txt"
                warn "  layer-shell-qt5 listed as AUR — required or the greeter draws nothing"
            fi
            info "  added Qt5 runtime + wayland platform + layer-shell"
        else
            for qp in qt6-declarative qt6-5compat qt6-svg qt6-multimedia \
                      qt6-wayland layer-shell-qt; do
                pacman -Si "$qp" &>/dev/null && add_pkg "$qp"
            done
            info "  added Qt6 runtime + wayland platform + layer-shell"
        fi

        # Video/audio backgrounds need GStreamer decoders
        if find "$S/themes/$tname" -type f \
            \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' \
               -o -iname '*.avi' -o -iname '*.mov' \) 2>/dev/null | grep -q .; then
            for gp in gst-libav gst-plugins-base gst-plugins-good \
                      gst-plugins-bad gst-plugins-ugly; do
                pacman -Si "$gp" &>/dev/null && add_pkg "$gp"
            done
            info "  theme has video assets → added GStreamer codecs"
        fi

        # Fonts named inside the theme must exist or text renders as fallback
        while IFS= read -r fam; do
            [ -z "$fam" ] && continue
            fc-list : family 2>/dev/null | tr ',' '\n' | grep -qixF "$fam" || {
                warn "  theme wants font '$fam' which is not installed here"
                echo "$fam" >> "$S/missing-fonts.txt"
            }
        done < <(grep -rhoP 'font\.family\s*:\s*"\K[^"]+' \
                    "$S/themes/$tname" 2>/dev/null | sort -u)
    elif [ "$tname" = "$ACTIVE_SDDM" ]; then
        add_pkg "$own"
        info "Active SDDM theme is from package: $own"
    fi
done

# A custom SDDM theme makes SDDM itself a hard requirement.
# Since Plasma 6.6, Plasma Login Manager is the default on many distros and it
# CANNOT load QML themes at all — it is locked to Breeze.
if [ -n "$(ls -A "$S/themes" 2>/dev/null)" ] || [ -n "$ACTIVE_SDDM" ]; then
    add_pkg "sddm"
    pacman -Qq sddm-kcm &>/dev/null && add_pkg "sddm-kcm"
    echo "REQUIRES_SDDM=yes" >> "$OUT/ACTIVE-THEME"
    warn "Custom login theme → recipient MUST run SDDM, not Plasma Login Manager"
fi

# =============================================================================
header "6 · Widgets & KWin effects"
# =============================================================================
W="$OUT/widgets"; mkdir -p "$W/files"
classify_plasmoids "$W/plasmoids"

# Package-provided plasmoids become dependencies.
# Stock ones (plasma-desktop, plasma-workspace, kdeplasma-addons) are filtered
# out later by BASE_PROVIDED — only third-party widget packages matter here.
while IFS= read -r p; do add_pkg "$p"; done < "$W/plasmoids.packages"

# File-based plasmoids get shipped
while IFS= read -r d; do
    [ -d "$d" ] || continue
    kp_cp "$d" "$W/files/$(basename "$d")" 2>/dev/null
done < "$W/plasmoids.files"

safe_copy_dir "$HOME/.local/share/kwin/scripts" "$W/kwin-scripts"
safe_copy_dir "$HOME/.local/share/kwin/effects" "$W/kwin-effects"

# Which effects are switched on, plus each effect's own settings
# (ShapeCorners radius/outline, blur strength, and so on). Copying kwinrc is
# not enough — applying a global theme rewrites it.
save_kwin_effects "$W/kwin-effects-state"
if [ -s "$W/kwin-effects-state" ]; then
    success "Recorded $(grep -c 'Enabled=true' "$W/kwin-effects-state" 2>/dev/null || echo 0) enabled effects"
fi

# Compiled KWin effects (ShapeCorners, ForceBlur, etc.) are plugins in
# /usr/lib — they come from packages and must be installed, not copied.
for effdir in /usr/lib/qt6/plugins/kwin/effects/plugins /usr/lib/qt/plugins/kwin/effects/plugins; do
    [ -d "$effdir" ] || continue
    while IFS= read -r sofile; do
        eff=$(basename "$sofile" .so)
        # Only care about effects the user actually enabled
        grep -qi "${eff#kwin4_effect_}Enabled=true" "$W/kwin-effects-state" 2>/dev/null || \
        grep -qi "${eff}Enabled=true" "$W/kwin-effects-state" 2>/dev/null || continue
        own=$(owner_of_file "$sofile")
        if [ -n "$own" ]; then
            case "$own" in
                kwin|plasma-desktop|plasma-workspace) ;;   # stock, skip
                *) add_pkg "$own"; success "Compiled effect $eff → $own" ;;
            esac
        fi
    done < <(find "$effdir" -name '*.so' 2>/dev/null)
done

# ShapeCorners is the most common third-party effect and is easy to miss
# because its plugin filename does not match its config key.
if grep -qi 'shapecorners' "$HOME/.config/kwinrc" 2>/dev/null; then
    for cand in kwin-effect-rounded-corners kwin-effects-shapecorners \
                kwin-effect-shapecorners kde-rounded-corners; do
        pacman -Qq "$cand" &>/dev/null && { add_pkg "$cand"; \
            success "ShapeCorners provided by $cand"; break; }
    done
fi

# =============================================================================
header "7 · GTK"
# =============================================================================
G="$OUT/gtk"; mkdir -p "$G"
safe_copy     "$HOME/.config/gtk-3.0"     "$G/gtk-3.0"
safe_copy     "$HOME/.config/gtk-4.0"     "$G/gtk-4.0"
safe_copy     "$HOME/.gtkrc-2.0"          "$G/gtkrc-2.0"
safe_copy_dir "$HOME/.local/share/themes" "$G/themes"

# =============================================================================
header "8 · Wallpapers (in use only)"
# =============================================================================
WP="$OUT/wallpapers"; mkdir -p "$WP"
grep -oP '(?<=^Image=).*' "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null | \
    sed 's|^file://||' | sort -u | while read -r img; do
    [ -f "$img" ] || continue
    kp_cp "$img" "$WP/$(basename "$img")" 2>/dev/null && \
        success "Wallpaper: $(basename "$img")"
done
safe_copy_dir "$HOME/.local/share/wallpapers" "$WP/local-wallpapers"

# =============================================================================
header "9 · Spicetify"
# =============================================================================
if [ -d "$HOME/.config/spicetify" ]; then
    SP="$OUT/spicetify"; mkdir -p "$SP"
    safe_copy_dir "$HOME/.config/spicetify/Themes"     "$SP/Themes"
    safe_copy_dir "$HOME/.config/spicetify/Extensions" "$SP/Extensions"
    for f in config-xpui.ini config.ini; do
        if [ -f "$HOME/.config/spicetify/$f" ]; then
            grep -vE '^(username|password|cookie|token)' \
                "$HOME/.config/spicetify/$f" > "$SP/$f" 2>/dev/null
            success "Spicetify $f (credentials stripped)"
        fi
    done
else
    info "Spicetify not installed — skipping"
fi

# =============================================================================
header "9b · Rice tooling & extra paths"
# =============================================================================
# Customization that lives outside Plasma's own config: alternative shells,
# colour-generation tools, launchers, notification daemons, wallpaper managers.
EX="$OUT/extras"; mkdir -p "$EX/config" "$EX/local-share" "$EX/bin"

FOUND_EXTRAS=0
for name in "${RICE_CONFIG_PATHS[@]}"; do
    if [ -e "$HOME/.config/$name" ]; then
        kp_cp "$HOME/.config/$name" "$EX/config/$name" 2>/dev/null && {
            success "extras: ~/.config/$name"
            FOUND_EXTRAS=$((FOUND_EXTRAS+1))
        }
        # Pull in the matching package if one owns the binary
        if command -v "$name" &>/dev/null; then
            own=$(owner_of_file "$(command -v "$name")")
            [ -n "$own" ] && add_pkg "$own"
        fi
    fi
done

for name in "${RICE_LOCAL_SHARE_PATHS[@]}"; do
    case "$name" in
        color-schemes|aurorae|kwin|konsole) continue ;;   # already handled
    esac
    if [ -e "$HOME/.local/share/$name" ]; then
        kp_cp "$HOME/.local/share/$name" "$EX/local-share/$name" 2>/dev/null && \
            success "extras: ~/.local/share/$name"
    fi
done

# User scripts a rice depends on (custom hyprctl wrappers, toggles, etc.)
if [ -d "$HOME/.local/bin" ]; then
    kp_cp_contents "$HOME/.local/bin" "$EX/bin" 2>/dev/null && \
        success "extras: ~/.local/bin ($(ls -1 "$HOME/.local/bin" 2>/dev/null | wc -l) scripts)"
fi

# User systemd units that drive theming daemons
if [ -d "$HOME/.config/systemd/user" ]; then
    mkdir -p "$EX/systemd-user"
    while IFS= read -r unit; do
        case "$(basename "$unit")" in
            *material*|*matugen*|*wallpaper*|*swww*|*theme*|*color*)
                kp_cp "$unit" "$EX/systemd-user/" 2>/dev/null && \
                    success "extras: $(basename "$unit")" ;;
        esac
    done < <(find "$HOME/.config/systemd/user" -maxdepth 1 -name '*.service' -o -name '*.timer' 2>/dev/null)
fi

# Anything the user asked for explicitly with --include
for extra in "${EXTRA_INCLUDES[@]}"; do
    if [ -e "$extra" ]; then
        mkdir -p "$EX/manual"
        kp_cp "$extra" "$EX/manual/" 2>/dev/null && \
            success "included by request: $extra"
        echo "$extra" >> "$EX/manual/ORIGINAL-PATHS.txt"
    else
        warn "--include path not found: $extra"
    fi
done

[ "$FOUND_EXTRAS" -eq 0 ] && info "No rice tooling detected"

# ── Auto-sweep for anything unrecognised ─────────────────────────────────────
if [ "$DO_SWEEP" = "yes" ]; then
    SWEEP="$OUT/UNSHIPPED-PATHS.txt"
    sweep_unknown_paths "$SWEEP" \
        "${RICE_CONFIG_PATHS[@]}" "${RICE_LOCAL_SHARE_PATHS[@]}" \
        gtk-3.0 gtk-4.0 fontconfig spicetify systemd environment.d \
        user-dirs.dirs autostart kdedefaults menus
    if [ -s "$SWEEP" ]; then
        echo ""
        info "Config directories NOT included in this pack:"
        while IFS='|' read -r path size; do
            printf "    %-52s %s\n" "${path/#$HOME/~}" "$size"
        done < "$SWEEP" | head -25
        [ "$(wc -l < "$SWEEP")" -gt 25 ] && \
            info "    ... and $(( $(wc -l < "$SWEEP") - 25 )) more (see UNSHIPPED-PATHS.txt)"
        echo ""
        info "If any of these are part of your look, re-run with:"
        info "  $0 <dest> --include ~/.config/<name>"
    fi
fi

# =============================================================================
header "9d · Setups that need their own installer"
# =============================================================================
# Some desktops are whole frameworks, not themes: a replacement shell, compiled
# widgets, their own PKGBUILDs. Copying files cannot reproduce them, and
# shipping a pack that half-works is worse than saying so plainly.

EXT_REPORT="$OUT/EXTERNAL-SETUPS.txt"
: > "$EXT_REPORT"
EXT_FOUND=0

flag_external() {
    local label="$1" path="$2" advice="$3"
    [ -e "$path" ] || return
    EXT_FOUND=1
    warn "$label"
    info "   $advice"
    {
        echo "== $label =="
        echo "detected at: ${path/#$HOME/\~}"
        echo "$advice"
        echo ""
    } >> "$EXT_REPORT"
}

flag_external "Caelestia (Quickshell-based shell)" \
    "$HOME/.config/quickshell/caelestia" \
    "Not reproducible by file copy. Install with:
     git clone https://github.com/ladybug-me/caelestia-dots-kde ~/caelestia-dots-kde
     cd ~/caelestia-dots-kde && bash ./setup.sh"

flag_external "Caelestia configuration" \
    "$HOME/.config/caelestia" \
    "Part of caelestia-dots-kde — use that repo's setup.sh"

[ -d "$HOME/.config/quickshell/caelestia" ] || \
flag_external "Quickshell (replacement shell)" \
    "$HOME/.config/quickshell" \
    "Configs are shipped, but quickshell itself must be installed first:
     paru -S quickshell   (then copy the config back)"

flag_external "AGS / Astal shell" \
    "$HOME/.config/ags" \
    "Install AGS separately, then restore the config from extras/"

flag_external "Eww widgets" \
    "$HOME/.config/eww" \
    "Install eww separately, then restore the config from extras/"

flag_external "end-4 illogical-impulse dots" \
    "$HOME/.config/illogical-impulse" \
    "Use the end-4/dots-hyprland installer"

flag_external "Material You colour daemon" \
    "$HOME/.config/kde-material-you-colors" \
    "Install kde-material-you-colors and enable its user service:
     systemctl --user enable --now kde-material-you-colors"

# Compiled KWin effects that no package owns — machine-specific binaries
if [ -s "$W/kwin-effects.binary-unowned" ] 2>/dev/null; then
    EXT_FOUND=1
    warn "Compiled KWin effects with no owning package"
    sed 's/^/     /' "$W/kwin-effects.binary-unowned"
    info "   These .so plugins are built against this machine's KWin ABI."
    info "   The recipient must install them from the AUR, not copy them."
    {
        echo "== Compiled KWin effects (no package) =="
        cat "$W/kwin-effects.binary-unowned"
        echo "Install these from the AUR on the target machine."
        echo ""
    } >> "$EXT_REPORT"
fi

if [ "$EXT_FOUND" -eq 1 ]; then
    echo ""
    warn "This desktop includes parts a theme pack cannot reproduce."
    warn "They are listed in EXTERNAL-SETUPS.txt inside the pack, with"
    warn "install instructions. Everything else is shipped normally."
else
    success "Nothing here needs an external installer — the pack is self-contained"
    rm -f "$EXT_REPORT"
fi

# =============================================================================
header "10 · Resolving dependencies (assume a bare system)"
# =============================================================================
# Philosophy: assume NOTHING exists on the target machine. Every package the
# theme needs to render is listed, including the Plasma runtime itself.
# pacman resolves transitive dependencies, so only direct requirements go here.

# ── Core runtime: a working Plasma 6 desktop ─────────────────────────────────
for p in \
    plasma-desktop plasma-workspace plasma-framework libplasma \
    plasma5support plasma-activities plasma-integration \
    plasma-systemmonitor plasma-pa plasma-nm \
    kdeplasma-addons kde-cli-tools kscreen \
    kwin kwayland systemsettings \
    breeze breeze-gtk breeze-icons \
    kirigami kirigami-addons \
    kcoreaddons kconfig kcmutils knotifications kwindowsystem \
    kdeclarative ksvg kiconthemes kitemmodels kquickcharts \
    kio kservice kglobalaccel kded \
    xdg-desktop-portal-kde \
    polkit-kde-agent; do
    pacman -Si "$p" &>/dev/null && add_pkg "$p"
done

# ── Qt runtime ───────────────────────────────────────────────────────────────
for p in \
    qt6-base qt6-declarative qt6-svg qt6-5compat qt6-multimedia \
    qt6-wayland qt6-imageformats qt6-shadertools qt6-translations \
    qt6-quicktimeline qt6-virtualkeyboard qt6-graphs \
    qt5-graphicaleffects qt5-quickcontrols2; do
    pacman -Si "$p" &>/dev/null && add_pkg "$p"
done

# ── Login manager (custom QML themes need SDDM, not Plasma Login Manager) ────
add_pkg "sddm"
pacman -Si sddm-kcm &>/dev/null && add_pkg "sddm-kcm"

# ── Theming engines & tools ──────────────────────────────────────────────────
for p in kvantum kvantum-qt5 qt6ct qt5ct nwg-look \
         gtk3 gtk4 gsettings-desktop-schemas \
         xdg-user-dirs xsettingsd; do
    pacman -Si "$p" &>/dev/null && add_pkg "$p"
done

# ── Fonts referenced by the theme (plus safe fallbacks) ──────────────────────
for p in ttf-jetbrains-mono ttf-meslo-nerd ttf-nerd-fonts-symbols \
         noto-fonts noto-fonts-emoji noto-fonts-cjk \
         ttf-dejavu ttf-liberation cantarell-fonts \
         awesome-terminal-fonts; do
    pacman -Si "$p" &>/dev/null && add_pkg "$p"
done

# ── Audio stack (needed by the visualizer widget) ────────────────────────────
for p in cava pipewire pipewire-pulse wireplumber; do
    pacman -Si "$p" &>/dev/null && add_pkg "$p"
done

# ── Everything detected from the actual theme content ────────────────────────
# QML imports across every shipped asset
scan_qml_deps "$OUT/qml.txt" \
    "$S/themes" "$T" "$W/files" "$W/kwin-scripts" "$W/kwin-effects" \
    "$HOME/.local/share/plasma"
while IFS= read -r p; do add_pkg "$p"; done < "$OUT/qml.txt"

# Widget packages found during classification
while IFS= read -r p; do add_pkg "$p"; done < "$W/plasmoids.packages"

# ── Deduplicate ──────────────────────────────────────────────────────────────
sort -u "$DEPS/native.txt" -o "$DEPS/native.txt"
sort -u "$DEPS/aur.txt"    -o "$DEPS/aur.txt"

# ── Drop distro theme packages the user does not actually use ────────────────
# These are shipped-by-default alternate themes, not part of this look.
while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    case "$pkg" in
        cachyos-*-kde-theme-git|cachyos-iridescent-kde|cachyos-themes-*)
            keep=no
            while IFS= read -r owned; do
                bn=$(basename "$owned")
                if grep -qxF "$bn" <(grep -hoP '(?<==).*' "$OUT/ACTIVE-THEME"); then
                    keep=yes; break
                fi
            done < <(grep "^$pkg " "$OWNER_CACHE" | awk '{print $2}' | \
                     grep -E '/(desktoptheme|look-and-feel|color-schemes|aurorae|sddm/themes)/[^/]+/$')
            if [ "$keep" = "no" ]; then
                sed -i "/^${pkg}$/d" "$DEPS/native.txt"
                skipmsg "Unused alternate theme, dropped: $pkg"
            fi
            ;;
    esac
done < <(cat "$DEPS/native.txt")

# ── Validate every listed package actually resolves ──────────────────────────
: > "$DEPS/unresolved.txt"
for listfile in "$DEPS/native.txt" "$DEPS/aur.txt"; do
    [ -s "$listfile" ] || continue
    tmpok=$(mktemp)
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if [ "$listfile" = "$DEPS/native.txt" ]; then
            if pacman -Si "$pkg" &>/dev/null; then
                echo "$pkg" >> "$tmpok"
            else
                echo "$pkg" >> "$DEPS/unresolved.txt"
            fi
        else
            echo "$pkg" >> "$tmpok"
        fi
    done < "$listfile"
    sort -u "$tmpok" > "$listfile"
    rm -f "$tmpok"
done

# ── Record versions so the recipient can see what this was built against ─────
{
    echo "# package  version-on-source-machine"
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        v=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
        printf '%s  %s\n' "$pkg" "${v:-not-installed-here}"
    done < <(cat "$DEPS/native.txt" "$DEPS/aur.txt" 2>/dev/null)
} > "$DEPS/versions.txt"

NCOUNT=$(wc -l < "$DEPS/native.txt")
ACOUNT=$(wc -l < "$DEPS/aur.txt" 2>/dev/null || echo 0)

echo ""
success "Dependency list is self-sufficient — assumes nothing pre-installed"
info "$NCOUNT native + $ACOUNT AUR packages"
echo ""
echo -e "${BOLD}  native:${NC}"
sed 's/^/    /' "$DEPS/native.txt"
if [ -s "$DEPS/aur.txt" ]; then
    echo -e "${BOLD}  AUR:${NC}"
    sed 's/^/    /' "$DEPS/aur.txt"
fi
if [ -s "$DEPS/unresolved.txt" ]; then
    echo ""
    warn "Not found in your repos (recipient may need them from AUR):"
    sed 's/^/    /' "$DEPS/unresolved.txt"
fi
if [ -s "$OUT/qml.txt.unmapped" ]; then
    echo ""
    warn "Unmapped QML modules — review these manually:"
    sed 's/^/    /' "$OUT/qml.txt.unmapped"
fi

# Packages the user unticked in HermitCrab
filter_pkgs "$DEPS/native.txt"
filter_pkgs "$DEPS/aur.txt"

# =============================================================================
header "11 · Security scan"
# =============================================================================
write_manifest "$OUT" "themepack" "yes"

cat > "$OUT/README.md" << 'READMEEOF'
# KDE Plasma 6 Theme Pack

Visual customization export. Contains no passwords, keys, or personal data.

## Install

```bash
./kde-restore.sh kde-themepack-DATE.tar.gz
```

The restore script will install required packages, copy theme files, and
apply the theme selections recorded in `ACTIVE-THEME`.

## Requirements

- KDE Plasma 6 (Wayland or X11)
- Arch-based distro (CachyOS, EndeavourOS, Arch, Manjaro)
- An AUR helper (`yay` or `paru`) if `dependencies/aur.txt` is non-empty
- **SDDM as your login manager**, if this pack includes a custom login theme

Plasma 5 is not supported — the QML imports differ and the theme will break.

### About the login screen

Since Plasma 6.6, many distros default to **Plasma Login Manager (PLM)**
instead of SDDM. PLM is locked to the Breeze appearance and cannot load QML
login themes at all. If this pack ships a custom login theme, you need SDDM:

```bash
sudo pacman -S sddm sddm-kcm
sudo systemctl enable --force sddm.service
```

The restore script checks for this and offers to do it for you.

## Contents

| Path | What |
|---|---|
| `config/` | Appearance settings, panel layout |
| `themes/` | Plasma themes, color schemes, window decorations, Kvantum |
| `icons/` | Icon and cursor themes |
| `fonts/` | Fonts referenced by the theme |
| `sddm/` | Login screen theme |
| `widgets/` | Plasmoids and KWin effects |
| `gtk/` | GTK theme settings |
| `wallpapers/` | Wallpapers in use |
| `spicetify/` | Spotify theme (credentials stripped) |
| `dependencies/` | Package lists |
| `ACTIVE-THEME` | Which theme/color/cursor to select |

## Not included

SSH/GPG keys · saved passwords · browser data · WiFi credentials ·
shell configs · keyboard shortcuts · KDE Connect pairings · crontabs

## After installing

Log out and back in. If the panel looks wrong, right-click the desktop →
Enter Edit Mode. For Spicetify, run `spicetify apply`.
READMEEOF

if scan_for_secrets "$OUT"; then
    info "Compressing..."
    tar -czf "$ARCHIVE" \
        --exclude='*/.snapshots/*' \
        --warning=no-file-changed \
        -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null
    echo ""
    echo -e "${BOLD}${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║       THEME PACK READY TO SHARE        ║${NC}"
    echo -e "${BOLD}${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Folder  : ${CYAN}$OUT${NC}  ($(du -sh "$OUT" 2>/dev/null | cut -f1))"
    [ -f "$ARCHIVE" ] && \
    echo -e "  Archive : ${CYAN}$ARCHIVE${NC}  ($(du -sh "$ARCHIVE" 2>/dev/null | cut -f1))"
    echo ""
    echo    "  Send the .tar.gz to your friends — they open it with HermitCrab → Restore."
    echo    "  (Without HermitCrab: kde-restore.sh + kde-lib.sh from the same repo.)"
    echo ""
else
    echo ""
    echo -e "${BOLD}${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║      ARCHIVE BLOCKED — NOT CREATED     ║${NC}"
    echo -e "${BOLD}${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo    "  Sensitive files were found in the export (listed above)."
    echo    "  Review and delete them from:"
    echo -e "    ${CYAN}$OUT${NC}"
    echo    "  then re-run to build the archive, or compress manually."
    echo ""
    exit 1
fi
