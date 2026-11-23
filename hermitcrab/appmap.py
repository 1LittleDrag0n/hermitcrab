"""Hints for matching installed apps to the folders they keep in $HOME.

Most apps are matched automatically by name (package name, launcher file,
executable, window class). This table covers the ones whose folders don't
look like their package name, and marks sub-folders that are usually huge
and should start unticked (game libraries, VM images).

Paths use ~ for $HOME. Keys are package names; add aliases for -bin / -git
variants by listing them in PACKAGE_ALIASES.
"""

APP_HINTS: dict[str, list[str]] = {
    "davinci-resolve": [
        "~/.local/share/DaVinciResolve",
        "~/.config/Blackmagic Design",
    ],
    "blender": ["~/.config/blender", "~/.cache/blender"],
    "steam": ["~/.local/share/Steam", "~/.steam"],
    "code": ["~/.config/Code", "~/.vscode"],
    "vscodium": ["~/.config/VSCodium", "~/.vscode-oss"],
    "discord": ["~/.config/discord"],
    "vesktop": ["~/.config/vesktop"],
    "obs-studio": ["~/.config/obs-studio"],
    "krita": ["~/.config/kritarc", "~/.local/share/krita"],
    "gimp": ["~/.config/GIMP"],
    "inkscape": ["~/.config/inkscape"],
    "spotify": ["~/.config/spotify", "~/.cache/spotify"],
    "telegram-desktop": ["~/.local/share/TelegramDesktop"],
    "lutris": ["~/.config/lutris", "~/.local/share/lutris", "~/.cache/lutris"],
    "heroic-games-launcher": ["~/.config/heroic"],
    "libreoffice-fresh": ["~/.config/libreoffice"],
    "libreoffice-still": ["~/.config/libreoffice"],
    "thunderbird": ["~/.thunderbird"],
    "kdenlive": ["~/.config/kdenliverc", "~/.local/share/kdenlive"],
    "waydroid": ["~/.local/share/waydroid"],
    "android-studio": ["~/.config/Google", "~/.local/share/Google"],
    "prismlauncher": ["~/.local/share/PrismLauncher"],
    "bottles": ["~/.local/share/bottles"],
    "zed": ["~/.config/zed", "~/.local/share/zed"],
    "obsidian": ["~/.config/obsidian"],
    "virt-manager": ["~/.config/virt-manager"],
    "kitty": ["~/.config/kitty"],
    "alacritty": ["~/.config/alacritty"],
    "mpv": ["~/.config/mpv"],
    "vlc": ["~/.config/vlc"],
    "unreal-engine": ["~/.config/Epic", "~/.config/Unreal Engine"],
}

# Variant package names that should use another entry's hints
PACKAGE_ALIASES: dict[str, str] = {
    "davinci-resolve-studio": "davinci-resolve",
    "davinci-resolve-beta": "davinci-resolve",
    "visual-studio-code-bin": "code",
    "vscodium-bin": "vscodium",
    "discord-canary": "discord",
    "spotify-launcher": "spotify",
    "heroic-games-launcher-bin": "heroic-games-launcher",
    "obsidian-bin": "obsidian",
    "zed-git": "zed",
    "prismlauncher-bin": "prismlauncher",
    "unreal-engine-bin": "unreal-engine",
    "blender-git": "blender",
}

# Sub-folders that start UNticked because they are usually enormous and can
# be re-downloaded. Shown as their own child so the rest of the app still moves.
HEAVY_SUBDIRS: dict[str, str] = {
    "~/.local/share/Steam/steamapps": "Game library — re-download instead",
    "~/.local/share/waydroid/images": "Android system image",
    "~/.local/share/bottles/bottles": "Windows prefixes",
    "~/.local/share/lutris/runners": "Downloaded runners",
    "~/.local/share/PrismLauncher/instances": "Minecraft instances",
    "~/.local/share/DaVinciResolve/CacheClip": "Render cache",
}

# Apps whose data is handled elsewhere (Browsers section) — never listed as apps
BROWSER_PACKAGES = {
    "brave-bin", "brave", "firefox", "firefox-developer-edition",
    "zen-browser-bin", "zen-browser", "librewolf", "librewolf-bin",
}
BROWSER_DIRS = {
    "~/.config/BraveSoftware", "~/.mozilla", "~/.zen", "~/.librewolf",
    "~/.cache/BraveSoftware", "~/.cache/mozilla", "~/.cache/zen",
}

# Suffixes stripped from package names before matching folder names
PKG_SUFFIXES = ("-bin", "-git", "-appimage", "-stable", "-beta", "-nightly",
                "-desktop", "-studio", "-launcher", "-qt", "-qt6", "-gtk")

# Folders in ~/.local/share that are never worth moving
SKIP_LOCAL_SHARE = {
    "Trash", "recently-used.xbel", "baloo", "kactivitymanagerd",
    "RecentDocuments", "gvfs-metadata", "flatpak", "Steam/logs",
}

# Folders in ~/.config that are never worth moving
SKIP_CONFIG = {
    "pulse",             # machine-specific audio cookie
    "session",           # KDE session restore state
    "QtProject.conf",
}
