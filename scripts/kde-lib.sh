#!/usr/bin/env bash
# =============================================================================
#  kde-lib.sh — shared helpers for kde-migrate.sh / kde-themepack.sh / kde-restore.sh
#  Sourced by the other scripts. Not meant to be run directly.
# =============================================================================

# Some launchers (app menus, systemd) start programs without $USER / $HOME;
# every script runs with `set -u`, so make sure they exist.
: "${USER:=$(id -un)}"; export USER
: "${HOME:=$(getent passwd "$USER" | cut -d: -f6)}"; export HOME

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; }
skipmsg() { echo -e "${BLUE}[SKIP]${NC}  $*"; }
header()  { echo -e "\n${BOLD}${GREEN}══ $* ══${NC}"; }

ask() {
    # Answers can come from three places, in this order:
    #   1. KP_ANSWERS_FILE — lines of "<regex>\t<y|n>", matched against the prompt
    #   2. KP_NONINTERACTIVE=1 — take the prompt's default
    #   3. the keyboard
    # 1 and 2 are how the HermitCrab GUI drives these scripts without a terminal.
    local prompt="$1" default="${2:-y}" yn="" pat ans
    if [ -n "${KP_ANSWERS_FILE:-}" ] && [ -f "$KP_ANSWERS_FILE" ]; then
        while IFS=$'\t' read -r pat ans; do
            [ -z "$pat" ] && continue
            if [[ "$prompt" =~ $pat ]]; then yn="$ans"; break; fi
        done < "$KP_ANSWERS_FILE"
    fi
    [ -z "$yn" ] && [ "${KP_NONINTERACTIVE:-0}" = "1" ] && yn="$default"
    if [ -n "$yn" ]; then
        echo -e "${YELLOW}?${NC} $prompt → $yn"
        [[ "${yn,,}" == "y" ]]
        return
    fi
    [[ "$default" == "y" ]] && prompt="$prompt [Y/n]: " || prompt="$prompt [y/N]: "
    read -rp "$(echo -e "${YELLOW}?${NC} $prompt")" yn
    yn="${yn:-$default}"
    [[ "${yn,,}" == "y" ]]
}

# ── GUI integration (HermitCrab) ──────────────────────────────────────────────
# KP_EXCLUDE_FILE   absolute paths (one per line) that must not be copied.
#                   A path excludes itself and everything under it. Virtual
#                   entries start with "@" (e.g. @gpg, @crontab).
# KP_EXCLUDE_PKGS   package names (one per line) dropped from package lists.
# KP_INCLUDE_FILE   extra absolute paths under $HOME to capture (app data).
# KP_GUI=1          set by the GUI; skips the built-in app-config list because
#                   the GUI passes every app folder explicitly instead.
# SUDO_ASKPASS      when set, sudo uses it — a password dialog instead of a tty.

if [ -n "${SUDO_ASKPASS:-}" ]; then
    sudo() { command sudo -A "$@"; }
fi

KP_EXCLUDES=()
if [ -n "${KP_EXCLUDE_FILE:-}" ] && [ -f "$KP_EXCLUDE_FILE" ]; then
    while IFS= read -r _kp_line || [ -n "$_kp_line" ]; do
        [ -n "$_kp_line" ] && KP_EXCLUDES+=("${_kp_line%/}")
    done < "$KP_EXCLUDE_FILE"
fi

# is_excluded <path> — true if the path or one of its parents is excluded
is_excluded() {
    local p="${1%/}" e
    [ ${#KP_EXCLUDES[@]} -eq 0 ] && return 1
    for e in "${KP_EXCLUDES[@]}"; do
        [ "$p" = "$e" ] && return 0
        case "$p" in "$e"/*) return 0 ;; esac
    done
    return 1
}

# Excluded entries that live INSIDE <src>, printed relative to it
_kp_excluded_children() {
    local src="${1%/}" e
    [ ${#KP_EXCLUDES[@]} -eq 0 ] && return 0
    for e in "${KP_EXCLUDES[@]}"; do
        case "$e" in "$src"/*) printf '%s\n' "${e#"$src"/}" ;; esac
    done
}

_kp_short() { local p="$1"; echo "${p/#$HOME/\~}"; }

# kp_cp SRC DST — same meaning as `cp -a SRC DST`, but honours exclusions.
# Excluded children are skipped DURING the copy (rsync) so an unticked 8 GB
# cache is never read, not copied and deleted afterwards.
kp_cp() {
    local src="${1%/}" dst="${2%/}" target
    [ -e "$src" ] || return 1
    # Returns 3 when excluded, so callers' "&& success ..." stays quiet
    if is_excluded "$src"; then skipmsg "Excluded: $(_kp_short "$src")"; return 3; fi
    if [ -d "$dst" ]; then target="$dst/$(basename "$src")"; else target="$dst"; fi
    local -a rel=(); local r
    while IFS= read -r r; do [ -n "$r" ] && rel+=("$r"); done < <(_kp_excluded_children "$src")
    if [ ${#rel[@]} -eq 0 ]; then
        cp -a "$src" "$dst"
        return
    fi
    if [ -d "$src" ] && command -v rsync >/dev/null 2>&1; then
        local -a args=()
        for r in "${rel[@]}"; do args+=("--exclude=/$r"); done
        mkdir -p "$target" && rsync -a "${args[@]}" "$src/" "$target/"
    else
        cp -a "$src" "$dst" || return 1
        for r in "${rel[@]}"; do rm -rf -- "${target:?}/$r"; done
    fi
    for r in "${rel[@]}"; do skipmsg "Excluded: $(_kp_short "$src/$r")"; done
}

# kp_cp_contents SRC DST — same meaning as `cp -a SRC/. DST/`
kp_cp_contents() {
    local src="${1%/}" dst="${2%/}"
    [ -d "$src" ] || return 1
    if is_excluded "$src"; then skipmsg "Excluded: $(_kp_short "$src")"; return 3; fi
    local -a rel=(); local r
    while IFS= read -r r; do [ -n "$r" ] && rel+=("$r"); done < <(_kp_excluded_children "$src")
    mkdir -p "$dst"
    if [ ${#rel[@]} -eq 0 ]; then
        cp -a "$src/." "$dst/"
        return
    fi
    if command -v rsync >/dev/null 2>&1; then
        local -a args=()
        for r in "${rel[@]}"; do args+=("--exclude=/$r"); done
        rsync -a "${args[@]}" "$src/" "$dst/"
    else
        cp -a "$src/." "$dst/" || return 1
        for r in "${rel[@]}"; do rm -rf -- "${dst:?}/$r"; done
    fi
    for r in "${rel[@]}"; do skipmsg "Excluded: $(_kp_short "$src/$r")"; done
}

# filter_pkgs FILE — drop packages the user unticked
filter_pkgs() {
    local f="$1"
    [ -f "$f" ] || return 0
    [ -n "${KP_EXCLUDE_PKGS:-}" ] && [ -s "$KP_EXCLUDE_PKGS" ] || return 0
    local before after
    before=$(grep -c . "$f" 2>/dev/null || echo 0)
    grep -vxF -f "$KP_EXCLUDE_PKGS" "$f" > "$f.kp-tmp" || true
    mv -f "$f.kp-tmp" "$f"
    after=$(grep -c . "$f" 2>/dev/null || echo 0)
    [ "$before" != "$after" ] && skipmsg "$(basename "$f"): $((before - after)) package(s) excluded"
    return 0
}

# ── Paths that must NEVER be walked (btrfs snapshots, mounts, caches) ─────────
EXCLUDE_PATHS=(
    "/.snapshots"
    "/home/.snapshots"
    "/timeshift"
    "/run/timeshift"
    "/var/cache"
    "/proc" "/sys" "/dev"
)

# Build find(1) prune arguments from EXCLUDE_PATHS
find_prune_args() {
    local args=()
    for p in "${EXCLUDE_PATHS[@]}"; do
        args+=(-path "$p" -prune -o)
    done
    args+=(-path "*/.snapshots/*" -prune -o)
    printf '%s\n' "${args[@]}"
}

# ── Package ownership cache ───────────────────────────────────────────────────
# Built ONCE, synchronously (the v1 race condition is fixed here).
OWNER_CACHE=""

build_owner_cache() {
    [ -n "$OWNER_CACHE" ] && return 0
    OWNER_CACHE=$(mktemp)
    info "Building package ownership index (one moment)..."
    pacman -Ql 2>/dev/null > "$OWNER_CACHE"
    local lines
    lines=$(wc -l < "$OWNER_CACHE")
    success "Indexed $lines owned paths"
}

cleanup_owner_cache() { [ -n "$OWNER_CACHE" ] && rm -f "$OWNER_CACHE"; }

# owner_of <dir> → package owning that directory, or empty if unowned
owner_of() {
    [ -n "$OWNER_CACHE" ] || build_owner_cache
    local path="${1%/}"
    grep -m1 -F " $path/" "$OWNER_CACHE" 2>/dev/null | awk '{print $1}'
}

# owner_of_file <file> → package owning that EXACT file path.
# Needed for fonts: /usr/share/fonts/TTF/ holds files from many packages,
# so matching the directory would return whichever package happens to be first.
owner_of_file() {
    [ -n "$OWNER_CACHE" ] || build_owner_cache
    local f="$1"
    grep -m1 -F " $f" "$OWNER_CACHE" 2>/dev/null | \
        awk -v target="$f" '$2 == target {print $1}' | head -1
}

# ── Copy helpers ──────────────────────────────────────────────────────────────
safe_copy() {
    local src="$1" dst="$2"
    if [ ! -e "$src" ]; then warn "Not found: $src"; return 0; fi
    if is_excluded "$src"; then skipmsg "Excluded: $(_kp_short "$src")"; return 0; fi
    mkdir -p "$(dirname "$dst")"
    kp_cp "$src" "$dst" 2>/dev/null && success "Copied: $src" || \
        warn "Copy failed: $src"
}

safe_copy_dir() {
    local src="$1" dst="$2"
    if [ ! -d "$src" ]; then warn "Not found: $src"; return 0; fi
    if is_excluded "$src"; then skipmsg "Excluded: $(_kp_short "$src")"; return 0; fi
    kp_cp_contents "$src" "$dst" 2>/dev/null && success "Copied dir: $src" || \
        warn "Copy failed: $src"
}

# Restoring a folder onto an existing folder must MERGE into it. Plain
# `cp -a dir existing-dir` nests it instead (~/.config/fish/fish).
safe_restore() {
    if [ -d "$1" ]; then safe_copy_dir "$1" "$2"; else safe_copy "$1" "$2"; fi
}
safe_restore_dir() { safe_copy_dir "$@"; }

# ── Qt version detection ──────────────────────────────────────────────────────
# A theme can be Qt5 or Qt6 regardless of what the desktop runs. Getting this
# wrong is fatal for SDDM themes: the Qt6 greeter cannot load a Qt5 theme and
# silently falls back to the embedded theme — which looks like a BLACK SCREEN
# at login. Detect it from the import statements instead of assuming.
#
#   Qt5 markers:  import QtGraphicalEffects 1.0      (module only exists in Qt5)
#                 import QtMultimedia 5.11           (explicit 5.x version)
#                 import QtQuick.Controls 2.x + Styles
#   Qt6 markers:  import Qt5Compat.GraphicalEffects  (the Qt6 replacement)
#                 import QtMultimedia                (unversioned = Qt6)
#                 import QtQuick.Effects
#
# detect_qt_version <dir> → prints 5 or 6
detect_qt_version() {
    local dir="$1"
    [ -d "$dir" ] || { echo 6; return; }

    local q5=0 q6=0
    while IFS= read -r line; do
        case "$line" in
            *QtGraphicalEffects*)          q5=$((q5+3)) ;;
            *Qt5Compat.GraphicalEffects*)  q6=$((q6+3)) ;;
            *QtQuick.Controls.Styles*)     q5=$((q5+2)) ;;
            *QtQuick.Effects*)             q6=$((q6+2)) ;;
        esac
        # Any module imported with an explicit 5.x version is Qt5
        if echo "$line" | grep -qE 'import[[:space:]]+[A-Za-z0-9_.]+[[:space:]]+5\.[0-9]+'; then
            q5=$((q5+1))
        fi
    done < <(grep -rhE '^\s*import\s+' "$dir" --include='*.qml' 2>/dev/null)

    if [ "$q5" -gt "$q6" ]; then echo 5; else echo 6; fi
}

# ── QML import → Arch package mapping ─────────────────────────────────────────
# Takes the module name and the Qt major version the asset was written for.
map_qml_module() {
    local mod="$1" qt="${2:-6}"

    if [ "$qt" = "5" ]; then
        case "$mod" in
            QtGraphicalEffects)      echo "qt5-graphicaleffects"; return ;;
            QtMultimedia)            echo "qt5-multimedia";       return ;;
            QtQuick.Controls.Styles) echo "qt5-quickcontrols";    return ;;
            QtQuick.Controls|QtQuick.Layouts|QtQuick.Window|QtQuick|QtQml*)
                                     echo "qt5-declarative";      return ;;
            QtQuick.Dialogs|QtCore)  echo "qt5-base";             return ;;
            QtWebEngine*)            echo "qt5-webengine";        return ;;
            QtQuick.VirtualKeyboard) echo "qt5-virtualkeyboard";  return ;;
            Qt.labs.*)               echo "qt5-declarative";      return ;;
            SddmComponents)          echo "sddm";                 return ;;
        esac
    fi

    case "$mod" in
        Qt5Compat.GraphicalEffects)  echo "qt6-5compat" ;;
        QtGraphicalEffects)          echo "qt5-graphicaleffects" ;;
        QtMultimedia)                echo "qt6-multimedia" ;;
        QtWebEngine*)                echo "qt6-webengine" ;;
        QtQuick.VirtualKeyboard)     echo "qt6-virtualkeyboard" ;;
        QtQuick.Effects|QtQuick.Templates|QtQuick.Particles*|QtQuick.Shapes) echo "qt6-declarative" ;;
        QtQuick.Layouts|QtQuick.Controls|QtQuick.Window|QtQuick) echo "qt6-declarative" ;;
        QtQml*)                      echo "qt6-declarative" ;;
        Qt.labs.*)                   echo "qt6-declarative" ;;
        QtCore|QtQuick.Dialogs)      echo "qt6-base" ;;
        QtCharts)                    echo "qt6-charts" ;;
        QtPositioning)               echo "qt6-positioning" ;;
        QtLocation)                  echo "qt6-location" ;;
        SddmComponents)              echo "sddm" ;;
        org.kde.plasma.core|org.kde.plasma.components*|org.kde.plasma.extras|org.kde.plasma.plasmoid|org.kde.plasma.configuration|org.kde.draganddrop)
                                     echo "libplasma" ;;
        org.kde.plasma.plasma5support) echo "plasma5support" ;;
        org.kde.plasma.private.*|org.kde.plasma.workspace.*|org.kde.taskmanager|org.kde.plasma.networkmanagement)
                                     echo "plasma-workspace" ;;
        org.kde.kirigamiaddons.*)    echo "kirigami-addons" ;;   # must precede kirigami*
        org.kde.kirigami*)           echo "kirigami" ;;
        org.kde.kwindowsystem)       echo "kwindowsystem" ;;
        org.kde.kquickcontrols*)     echo "kdeclarative" ;;
        org.kde.kcmutils)            echo "kcmutils" ;;
        org.kde.config)              echo "kconfig" ;;
        org.kde.coreaddons)          echo "kcoreaddons" ;;
        org.kde.notification*)       echo "knotifications" ;;
        org.kde.ksvg)                echo "ksvg" ;;
        org.kde.breeze*)             echo "breeze" ;;
        org.kde.kwin*)               echo "kwin" ;;
        org.kde.activities)          echo "plasma-activities" ;;
        org.kde.bluezqt)             echo "bluez-qt" ;;
        org.kde.graphicaleffects)    echo "kquickimageeditor" ;;
        org.kde.iconthemes)          echo "kiconthemes" ;;
        org.kde.kitemmodels)         echo "kitemmodels" ;;
        org.kde.networkmanager)      echo "plasma-nm" ;;
        org.kde.kdeconnect)          echo "kdeconnect" ;;
        org.kde.pipewire)            echo "plasma-workspace" ;;
        org.kde.prison)              echo "prison" ;;
        org.kde.quickcharts*)        echo "kquickcharts" ;;
        *)                           echo "" ;;
    esac
}

# Scan directories for QML imports → package list in $1
# Each directory is version-detected independently, so a Qt5 SDDM theme sitting
# next to Qt6 plasmoids resolves to the right packages for both.
scan_qml_deps() {
    local out="$1"; shift
    local tmp_pkgs
    tmp_pkgs=$(mktemp)
    : > "${out}.unmapped"
    : > "${out}.modules"

    for d in "$@"; do
        [ -d "$d" ] || continue

        # Detect per-subdirectory where possible (each theme may differ)
        local subdirs=()
        while IFS= read -r sd; do subdirs+=("$sd"); done \
            < <(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        [ ${#subdirs[@]} -eq 0 ] && subdirs=("$d")

        for sd in "${subdirs[@]}"; do
            local qtver
            qtver=$(detect_qt_version "$sd")
            [ -n "${VERBOSE_QT:-}" ] && \
                info "  $(basename "$sd") → Qt$qtver"
            echo "$(basename "$sd")=$qtver" >> "${out}.qtversions"

            while IFS= read -r mod; do
                [ -z "$mod" ] && continue
                echo "$mod" >> "${out}.modules"
                local pkg
                pkg=$(map_qml_module "$mod" "$qtver")
                if [ -n "$pkg" ]; then
                    echo "$pkg" >> "$tmp_pkgs"
                else
                    echo "$mod" >> "${out}.unmapped"
                fi
            done < <(grep -rhoP '^\s*import\s+\K[A-Za-z0-9_.]+' "$sd" \
                        --include='*.qml' --include='*.js' 2>/dev/null | sort -u)
        done
    done

    sort -u "$tmp_pkgs" > "$out"
    sort -u "${out}.modules"   -o "${out}.modules"   2>/dev/null || true
    sort -u "${out}.unmapped"  -o "${out}.unmapped"  2>/dev/null || true
    sort -u "${out}.qtversions" -o "${out}.qtversions" 2>/dev/null || true
    rm -f "$tmp_pkgs"
}

# ── Plasmoid classification ───────────────────────────────────────────────────
# Writes two files: <out>.packages (install these) and <out>.files (ship these)
classify_plasmoids() {
    local out="$1"
    : > "${out}.packages"
    : > "${out}.files"

    build_owner_cache

    for base in "$HOME/.local/share/plasma/plasmoids" /usr/share/plasma/plasmoids; do
        [ -d "$base" ] || continue
        for d in "$base"/*/; do
            [ -d "$d" ] || continue
            local pname owner
            pname=$(basename "$d")
            owner=$(owner_of "$d")
            if [ -n "$owner" ]; then
                echo "$owner" >> "${out}.packages"
                info "  plasmoid $pname → package: $owner"
            else
                echo "$d" >> "${out}.files"
                info "  plasmoid $pname → ship files"
            fi
        done
    done

    sort -u "${out}.packages" -o "${out}.packages"
}

# ── Tier 2: rice / alternative-shell paths ────────────────────────────────────
# Customizations that live outside Plasma's own config system. These are real
# parts of a look but invisible to appletsrc/kdeglobals scanning.
RICE_CONFIG_PATHS=(
    quickshell caelestia ags eww waybar
    hypr hyprpanel
    matugen kde-material-you-colors wallust pywal
    swww hyprpaper azote variety
    fuzzel rofi wofi tofi anyrun
    dunst mako swaync
    cava
    fastfetch neofetch
    keyd
    polonium
    darkly
    conky
    picom
)

RICE_LOCAL_SHARE_PATHS=(
    quickshell caelestia
    color-schemes aurorae kwin konsole
    kio kservices5 kservices6
)

# Directories whose mere presence means "this is not a plain Plasma rice"
# — Tier 3: the setup ships its own installer and cannot be reproduced by
# copying files around.
declare -A TIER3_MARKERS=(
    ["$HOME/.config/quickshell"]="Quickshell (replaces Plasma panels entirely)"
    ["$HOME/.config/caelestia"]="Caelestia dots — has its own setup.sh"
    ["$HOME/.config/ags"]="AGS shell"
    ["$HOME/.config/eww"]="EWW widgets"
    ["$HOME/.config/hypr"]="Hyprland config"
)

# Packages that indicate a compiled / installer-managed rice
TIER3_PACKAGES="caelestia-quickshell-git quickshell quickshell-git \
kde-material-you-colors matugen matugen-bin darkly darkly-bin polonium"

# detect_tier3 <outfile> → returns 0 if a Tier-3 setup was found
detect_tier3() {
    local out="$1"
    : > "$out"
    local found=1

    for path in "${!TIER3_MARKERS[@]}"; do
        if [ -d "$path" ]; then
            echo "PATH|$path|${TIER3_MARKERS[$path]}" >> "$out"
            found=0
        fi
    done

    for pkg in $TIER3_PACKAGES; do
        if pacman -Qq "$pkg" &>/dev/null; then
            echo "PKG|$pkg|installed" >> "$out"
            found=0
        fi
    done

    # A user systemd service is a strong signal of installer-managed state
    if [ -d "$HOME/.config/systemd/user" ]; then
        while IFS= read -r unit; do
            case "$(basename "$unit")" in
                caelestia*|quickshell*|kde-material-you*|matugen*)
                    echo "UNIT|$(basename "$unit")|user service" >> "$out"
                    found=0 ;;
            esac
        done < <(find "$HOME/.config/systemd/user" -name '*.service' 2>/dev/null)
    fi

    return $found
}

# ── Auto-sweep: find customization dirs we don't already know about ───────────
# Lists directories under ~/.config and ~/.local/share that are NOT owned by
# any package and NOT already covered, so the user can decide to include them.
sweep_unknown_paths() {
    local out="$1"; shift
    local -a known=("$@")
    : > "$out"

    is_known() {
        local n="$1"
        for k in "${known[@]}"; do [ "$n" = "$k" ] && return 0; done
        return 1
    }

    for base in "$HOME/.config" "$HOME/.local/share"; do
        [ -d "$base" ] || continue
        for d in "$base"/*/; do
            [ -d "$d" ] || continue
            local n; n=$(basename "$d")
            is_known "$n" && continue
            # Skip caches and obvious app state
            case "$n" in
                *cache*|*Cache*|chromium|BraveSoftware|google-chrome|\
                Code|VSCodium|discord|Steam|steam|lutris|obs-studio|\
                pulse|dconf|gnupg|keyrings|Trash|recently-used*|\
                mime|applications|icons|fonts|themes|plasma|sddm|\
                kwin|konsole|color-schemes|aurorae|Kvantum|kvantum) continue ;;
            esac
            local sz; sz=$(du -sh "$d" 2>/dev/null | cut -f1)
            echo "$d|$sz" >> "$out"
        done
    done
}

# ── KWin effect state ─────────────────────────────────────────────────────────
# Effects are enabled by "<name>Enabled=true" keys in kwinrc. Copying kwinrc is
# not enough: plasma-apply-lookandfeel rewrites it, so the flags must be
# re-applied afterwards with kwriteconfig.
save_kwin_effects() {
    local out="$1"
    : > "$out"
    [ -f "$HOME/.config/kwinrc" ] || return
    # [Plugins] section holds the Enabled flags
    awk '/^\[Plugins\]/{f=1;next} /^\[/{f=0} f && /Enabled=/{print}' \
        "$HOME/.config/kwinrc" >> "$out"
    # Per-effect configuration sections (ShapeCorners, blur radius, etc.)
    awk '/^\[Effect-/{sec=$0} sec && /^[A-Za-z]/{print sec"|"$0} /^\[/ && !/^\[Effect-/{sec=""}' \
        "$HOME/.config/kwinrc" >> "${out}.effectconfig"
}

restore_kwin_effects() {
    local file="$1"
    [ -f "$file" ] || return
    local KW=kwriteconfig6
    command -v kwriteconfig6 &>/dev/null || KW=kwriteconfig5

    while IFS='=' read -r key val; do
        [ -z "$key" ] && continue
        $KW --file kwinrc --group Plugins --key "$key" "$val"
    done < "$file"

    if [ -f "${file}.effectconfig" ]; then
        while IFS='|' read -r sec line; do
            [ -z "$sec" ] && continue
            local grp="${sec#[}"; grp="${grp%]}"
            local k="${line%%=*}" v="${line#*=}"
            [ -z "$k" ] && continue
            $KW --file kwinrc --group "$grp" --key "$k" "$v"
        done < "${file}.effectconfig"
    fi
}

# ── Secret scanner (used by themepack before archiving) ───────────────────────
# Returns 0 if clean, 1 if suspicious files found. Prints findings.
scan_for_secrets() {
    local dir="$1"
    local found=0

    # Exact filenames that are always credential stores
    local EXACT_NAMES=(
        'id_rsa' 'id_ed25519' 'id_ecdsa' 'id_dsa'
        'key3.db' 'key4.db' 'logins.json' 'signons.sqlite'
        'Login Data' 'Login Data For Account' 'Web Data'
        'Cookies' 'cookies.sqlite' 'places.sqlite' 'formhistory.sqlite'
        'secring.gpg' 'trustdb.gpg' 'private-keys-v1.d'
        '.netrc' '.pgpass' 'shadow'
        '.bash_history' '.zsh_history' '.python_history'
        'kwalletrc'
    )

    # Extensions that are always credential material
    local EXT_PATTERNS=(
        '*.pem' '*.pfx' '*.p12' '*.keystore' '*.ovpn'
        '*.nmconnection' '*.kwl'
    )

    # Asset extensions that can never be a secret — never flag these,
    # icon themes legitimately contain names like "secrets.svg"
    is_asset() {
        case "${1,,}" in
            *.svg|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.xpm|*.ico|*.bmp|\
            *.ttf|*.otf|*.woff|*.woff2|*.mp4|*.webm|*.ogg|*.wav|*.mp3|\
            *.qml|*.desktop|*.theme|*.colors|*.kvconfig|*.po|*.mo) return 0 ;;
            *) return 1 ;;
        esac
    }

    echo ""
    info "Scanning export for anything sensitive..."

    for name in "${EXACT_NAMES[@]}"; do
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            error "SENSITIVE FILE: ${hit#$dir/}"
            found=1
        done < <(find "$dir" -name "$name" 2>/dev/null)
    done

    for pat in "${EXT_PATTERNS[@]}"; do
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            error "SENSITIVE FILE: ${hit#$dir/}"
            found=1
        done < <(find "$dir" -iname "$pat" 2>/dev/null)
    done

    # Fuzzy name patterns — only on non-asset files
    for pat in '*id_rsa*' '*id_ed25519*' '*credential*' '*password*'; do
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            is_asset "$hit" && continue
            error "SENSITIVE FILE: ${hit#$dir/}"
            found=1
        done < <(find "$dir" -iname "$pat" 2>/dev/null)
    done

    # Content-based scan on small text files
    local CONTENT_RE='BEGIN (RSA |OPENSSH |DSA |EC |PGP )?PRIVATE KEY|api[_-]?key[[:space:]]*[=:]|Bearer [A-Za-z0-9._-]{20,}|password[[:space:]]*[=:][[:space:]]*[^[:space:]]{4,}|psk=|AWS_SECRET'

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if grep -qiE "$CONTENT_RE" "$f" 2>/dev/null; then
            error "SENSITIVE CONTENT: ${f#$dir/}"
            found=1
        fi
    done < <(find "$dir" -type f -size -256k \
                \( -name '*.conf' -o -name '*.ini' -o -name '*.json' \
                   -o -name '*.txt' -o -name '*.sh' -o -name '*rc' \
                   -o -name '*.yaml' -o -name '*.yml' -o -name '*.env' \) 2>/dev/null)

    if [ "$found" -eq 0 ]; then
        success "Clean — nothing sensitive detected"
        return 0
    else
        return 1
    fi
}

# ── Manifest helpers ──────────────────────────────────────────────────────────
write_manifest() {
    local dir="$1" type="$2" redact="${3:-no}"
    {
        echo "TYPE=$type"
        echo "CREATED=$(date -Iseconds)"
        if [ "$redact" = "yes" ]; then
            echo "HOST=(redacted)"
            echo "USER=(redacted)"
        else
            echo "HOST=$(hostname)"
            echo "USER=$USER"
        fi
        echo "OS=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
        echo "KERNEL=$(uname -r)"
        echo "PLASMA=$(plasmashell --version 2>/dev/null | awk '{print $2}')"
        echo "QT=$(qmake6 -query QT_VERSION 2>/dev/null)"
        echo "SESSION=${XDG_SESSION_TYPE:-unknown}"
    } > "$dir/MANIFEST"
}

read_manifest_key() {
    local dir="$1" key="$2"
    grep -m1 "^$key=" "$dir/MANIFEST" 2>/dev/null | cut -d= -f2-
}

# ── Destination resolver (fixes trailing-slash bug) ───────────────────────────
resolve_dest() {
    local raw="$1" prefix="$2"
    local stamp="${prefix}-$(date +%Y%m%d_%H%M%S)"
    if [ -z "$raw" ]; then
        echo "$HOME/$stamp"
    else
        raw="${raw%/}"
        if [ -d "$raw" ]; then
            echo "$raw/$stamp"
        else
            echo "$raw"
        fi
    fi
}

# ── Binary KWin effects ───────────────────────────────────────────────────────
# Effects like ShapeCorners are compiled C++ plugins (.so), not QML. Copying the
# files to another machine does nothing useful — they must come from a package,
# built against that machine's KWin ABI. This finds them and returns package
# names instead of paths.
#
# classify_kwin_effects <out-prefix>
#   writes <out>.packages  (install these)
#         <out>.files      (ship these — QML/JS effects only)
#         <out>.binary-unowned (compiled but no package — cannot be shared)
classify_kwin_effects() {
    local out="$1"
    : > "${out}.packages"; : > "${out}.files"; : > "${out}.binary-unowned"
    build_owner_cache

    local dirs=(
        "$HOME/.local/share/kwin/effects"
        "/usr/share/kwin/effects"
        "/usr/lib/qt6/plugins/kwin/effects/plugins"
        "/usr/lib/qt/plugins/kwin/effects/plugins"
    )

    # Compiled plugins living in plugin dirs
    for d in /usr/lib/qt6/plugins/kwin/effects/plugins /usr/lib/qt/plugins/kwin/effects/plugins; do
        [ -d "$d" ] || continue
        for so in "$d"/*.so; do
            [ -f "$so" ] || continue
            local own
            own=$(owner_of_file "$so")
            local ename
            ename=$(basename "$so" .so)
            if [ -n "$own" ]; then
                echo "$own" >> "${out}.packages"
            else
                echo "$ename ($so)" >> "${out}.binary-unowned"
            fi
        done
    done

    # Effect folders — ship only if they contain no compiled objects
    for d in "$HOME/.local/share/kwin/effects" /usr/share/kwin/effects; do
        [ -d "$d" ] || continue
        for e in "$d"/*/; do
            [ -d "$e" ] || continue
            local own ename
            ename=$(basename "$e")
            own=$(owner_of "$e")
            if find "$e" -name '*.so' -o -name '*.so.*' 2>/dev/null | grep -q .; then
                if [ -n "$own" ]; then
                    echo "$own" >> "${out}.packages"
                else
                    echo "$ename ($e)" >> "${out}.binary-unowned"
                fi
            elif [ -n "$own" ]; then
                echo "$own" >> "${out}.packages"
            else
                echo "$e" >> "${out}.files"
            fi
        done
    done

    sort -u "${out}.packages" -o "${out}.packages"
    sort -u "${out}.files"    -o "${out}.files"
}

# ── Tier 2: extra customization paths ─────────────────────────────────────────
# Rice setups keep state well outside Plasma's own config. These are the paths
# worth sweeping; each is copied only if it exists.
EXTRA_CONFIG_PATHS=(
    # Alternative shells / bars
    "quickshell" "caelestia" "ags" "eww" "waybar" "ironbar" "yambar"
    # Launchers / menus
    "rofi" "wofi" "fuzzel" "tofi" "anyrun" "walker"
    # Notifications
    "dunst" "mako" "swaync" "fnott"
    # Colour generation / theming daemons
    "matugen" "kde-material-you-colors" "wallust" "pywal" "wal"
    "darkly" "colloid" "orchis"
    # Wallpaper engines
    "swww" "hyprpaper" "azote" "variety" "wpaperd" "mpvpaper"
    # Compositor-adjacent (some people run these alongside Plasma)
    "picom" "hypr" "kanshi" "wlsunset" "gammastep"
    # Panels / docks
    "latte-dock" "plank" "polybar" "tint2"
    # Terminals & prompt (appearance-relevant)
    "kitty" "alacritty" "foot" "wezterm" "ghostty" "starship.toml"
    # Input / shortcuts daemons
    "keyd" "kanata" "sxhkd"
    # Misc appearance
    "fastfetch" "neofetch" "btop" "cava" "spicetify"
    "qt5ct" "qt6ct" "nwg-look" "Kvantum"
)

EXTRA_LOCAL_SHARE_PATHS=(
    "quickshell" "caelestia" "ags" "eww"
    "color-schemes" "aurorae" "kwin" "konsole" "kstyle" "Kvantum"
    "wallpapers" "themes" "icons" "fonts"
)

EXTRA_HOME_PATHS=(
    ".local/bin"
    ".config/systemd/user"
    ".config/environment.d"
    ".config/autostart"
)

# sweep_extra_paths <dest-dir>  — copies whatever exists, reports what it found
sweep_extra_paths() {
    local dest="$1"
    mkdir -p "$dest/config" "$dest/local-share" "$dest/home"
    local found=0

    for name in "${EXTRA_CONFIG_PATHS[@]}"; do
        if [ -e "$HOME/.config/$name" ]; then
            cp -a "$HOME/.config/$name" "$dest/config/" 2>/dev/null && {
                success "  ~/.config/$name"; found=$((found+1)); }
        fi
    done

    for name in "${EXTRA_LOCAL_SHARE_PATHS[@]}"; do
        if [ -e "$HOME/.local/share/$name" ]; then
            cp -a "$HOME/.local/share/$name" "$dest/local-share/" 2>/dev/null && {
                success "  ~/.local/share/$name"; found=$((found+1)); }
        fi
    done

    for rel in "${EXTRA_HOME_PATHS[@]}"; do
        if [ -e "$HOME/$rel" ]; then
            mkdir -p "$dest/home/$(dirname "$rel")"
            cp -a "$HOME/$rel" "$dest/home/$rel" 2>/dev/null && {
                success "  ~/$rel"; found=$((found+1)); }
        fi
    done

    echo "$found"
}

# ── Tier 3: setups that need their own installer ──────────────────────────────
# Some rices are whole systems (custom shells, compiled widgets, their own
# PKGBUILDs). A file-copy pack cannot reproduce them, and pretending otherwise
# hands someone a half-working desktop. Detect and say so instead.
#
# detect_external_rice → prints findings, returns 0 if any were found
detect_external_rice() {
    local found=0
    local report="${1:-/dev/null}"
    : > "$report"

    check() {
        local label="$1" path="$2" advice="$3"
        [ -e "$path" ] || return
        found=1
        warn "  $label detected"
        info "     $advice"
        printf '%s\n  path: %s\n  %s\n\n' "$label" "$path" "$advice" >> "$report"
    }

    check "Caelestia (Quickshell)" "$HOME/.config/quickshell/caelestia" \
          "Install via: git clone https://github.com/ladybug-me/caelestia-dots-kde && bash setup.sh"
    check "Caelestia config"       "$HOME/.config/caelestia" \
          "Install via the caelestia-dots-kde repo's own setup.sh"
    check "Quickshell"             "$HOME/.config/quickshell" \
          "Quickshell configs are shipped, but the shell itself must be installed separately"
    check "AGS shell"              "$HOME/.config/ags" \
          "Install AGS separately, then copy the config"
    check "Eww widgets"            "$HOME/.config/eww" \
          "Install eww separately, then copy the config"
    check "end-4 dots"             "$HOME/.config/illogical-impulse" \
          "Use the end-4/dots-hyprland installer"

    # Compiled KWin effects with no owning package
    if [ -s "${KWIN_CLASSIFY_OUT:-/nonexistent}.binary-unowned" ]; then
        found=1
        warn "  Compiled KWin effects with no package:"
        sed 's/^/     /' "${KWIN_CLASSIFY_OUT}.binary-unowned"
        info "     These are machine-specific binaries and cannot be shared."
        info "     The recipient must install them from the AUR."
    fi

    return $((1 - found))
}

# ── Password-protected archives (GPG, AES-256) ────────────────────────────────
# The archive is compressed and encrypted in ONE stream, so an unencrypted
# .tar.gz never touches the disk.
#
# KP_PASSPHRASE_FILE  file holding the password (the GUI puts it in RAM, mode
#                     600, and deletes it afterwards). Without it, gpg asks
#                     for the password itself (terminal or desktop pop-up).
#                     The password is never placed on a command line, where
#                     other programs could read it from /proc.

_kp_gpg_pass() {
    if [ -n "${KP_PASSPHRASE_FILE:-}" ] && [ -r "$KP_PASSPHRASE_FILE" ]; then
        printf '%s\n' --batch --pinentry-mode loopback --passphrase-file "$KP_PASSPHRASE_FILE"
    fi
}

# kp_make_archive <folder> <archive> <encrypt yes|no>
kp_make_archive() {
    local folder="$1" archive="$2" enc="$3"
    local -a tar_args=(-cz --exclude='*/.snapshots/*' --warning=no-file-changed
                       -C "$(dirname "$folder")" "$(basename "$folder")")
    if [ "$enc" != "yes" ]; then
        tar -f "$archive" "${tar_args[@]}" 2>/dev/null
        local rc=$?
        # tar exits 1 for "file changed while reading" — the archive is still fine
        [ $rc -le 1 ] && [ -s "$archive" ]
        return
    fi
    command -v gpg >/dev/null || { error "gpg is not installed — cannot password-protect"; return 1; }
    local -a pass=()
    mapfile -t pass < <(_kp_gpg_pass)
    local errf; errf=$(mktemp)
    tar -f - "${tar_args[@]}" 2>/dev/null | \
        gpg --yes --no-symkey-cache "${pass[@]}" --symmetric --cipher-algo AES256 \
            --s2k-digest-algo SHA512 --s2k-mode 3 --s2k-count 65011712 \
            --compress-algo none --output "$archive" 2>"$errf"
    local s=("${PIPESTATUS[@]}")
    # show real gpg problems, hide first-run keyring chatter
    grep -v -E '^gpg: (keybox|directory|WARNING: unsafe)' "$errf" | sed 's/^/    /' >&2
    rm -f "$errf"
    if [ "${s[0]}" -le 1 ] && [ "${s[1]}" -eq 0 ] && [ -s "$archive" ]; then
        return 0
    fi
    rm -f "$archive"      # never leave a half-written encrypted file behind
    return 1
}

# kp_verify_archive <archive> — read every byte back (decrypting if needed)
kp_verify_archive() {
    local archive="$1"
    case "$archive" in
        *.gpg)
            local -a pass=()
            mapfile -t pass < <(_kp_gpg_pass)
            gpg --quiet --no-symkey-cache "${pass[@]}" --decrypt "$archive" 2>/dev/null | tar -tzf - >/dev/null 2>&1
            local s=("${PIPESTATUS[@]}")
            [ "${s[0]}" -eq 0 ] && [ "${s[1]}" -eq 0 ]
            ;;
        *)  tar -tzf "$archive" >/dev/null 2>&1 ;;
    esac
}

# kp_extract_archive <archive> <into-dir>
# Returns 2 for a wrong password, 1 for any other failure.
kp_extract_archive() {
    local archive="$1" into="$2"
    case "$archive" in
        *.gpg)
            command -v gpg >/dev/null || { error "gpg is not installed"; return 1; }
            local -a pass=()
            mapfile -t pass < <(_kp_gpg_pass)
            local errf; errf=$(mktemp)
            gpg --quiet --no-symkey-cache "${pass[@]}" --decrypt "$archive" 2>"$errf" | tar -xzf - -C "$into"
            local s=("${PIPESTATUS[@]}")
            if [ "${s[0]}" -ne 0 ]; then
                if grep -qiE 'bad (key|passphrase)|decryption failed' "$errf"; then
                    rm -f "$errf"; return 2
                fi
                sed 's/^/    /' "$errf"; rm -f "$errf"; return 1
            fi
            rm -f "$errf"
            [ "${s[1]}" -eq 0 ]
            ;;
        *)  tar -xzf "$archive" -C "$into" ;;
    esac
}

# Same filesystem? (staging on the same drive gains nothing)
kp_same_fs() { [ "$(stat -c %d "$1" 2>/dev/null)" = "$(stat -c %d "$2" 2>/dev/null)" ]; }

# kp_ask_new_password — terminal use: ask twice, keep it in a private RAM file
# for this run only. Sets KP_PASSPHRASE_FILE; deleted by kp_forget_password.
KP_OWN_PASSFILE=""
kp_ask_new_password() {
    local p1 p2 dir="${XDG_RUNTIME_DIR:-/tmp}"
    while true; do
        read -rsp "  Choose a password for the backup: " p1 </dev/tty; echo >&2
        [ -z "$p1" ] && { echo "  The password can't be empty." >&2; continue; }
        read -rsp "  Type it again: " p2 </dev/tty; echo >&2
        [ "$p1" = "$p2" ] && break
        echo "  They don't match — try again." >&2
    done
    KP_OWN_PASSFILE="$(mktemp -p "$dir" .hermitcrab-pass-XXXXXX)"
    chmod 600 "$KP_OWN_PASSFILE"
    printf '%s\n' "$p1" > "$KP_OWN_PASSFILE"
    unset p1 p2
    export KP_PASSPHRASE_FILE="$KP_OWN_PASSFILE"
}
kp_forget_password() { [ -n "$KP_OWN_PASSFILE" ] && rm -f "$KP_OWN_PASSFILE"; KP_OWN_PASSFILE=""; }
