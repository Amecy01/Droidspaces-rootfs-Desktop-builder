#!/usr/bin/env bash
# 最小外观补丁：只写 niri 布局/动画/blur、Matugen、GTK、fuzzel、alacritty
set -euo pipefail

USER_NAME="${1:?usage: install.sh <username>}"
HOME_DIR="/home/${USER_NAME}"
SRC="/usr/share/droidspaces-appearance"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "需要 root" >&2; exit 1; }
[[ -d "$HOME_DIR" ]] || { echo "用户目录不存在: $HOME_DIR" >&2; exit 1; }

install -d -o "$USER_NAME" -g "$USER_NAME" \
    "$HOME_DIR/.config/niri/dms" \
    "$HOME_DIR/.config/gtk-3.0" \
    "$HOME_DIR/.config/gtk-4.0" \
    "$HOME_DIR/.config/fuzzel" \
    "$HOME_DIR/.config/alacritty" \
    "$HOME_DIR/.config/matugen" \
    "$HOME_DIR/.local/share/fcitx5/themes/Matugen" \
    "$HOME_DIR/.config/btop/themes" \
    "$HOME_DIR/.config/cava/themes" \
    "$HOME_DIR/.config/yazi" \
    "$HOME_DIR/.config/fastfetch" \
    "$HOME_DIR/.cache/matugen" \
    "$HOME_DIR/Pictures/Wallpapers"

# niri 外观文件；不覆盖 DMS 自己生成的 dms/binds.kdl
for rel in niri/layout.kdl niri/animations.kdl niri/blur.kdl niri/appearance.kdl; do
    install -Dm644 "$SRC/$rel" "$HOME_DIR/.config/$rel"
done

# niri 主配置：没有就建，有就只追加 include，不动 DMS 已有内容
NIRI_CONFIG="$HOME_DIR/.config/niri/config.kdl"
if [[ ! -f "$NIRI_CONFIG" ]]; then
    install -Dm644 "$SRC/niri/config.kdl" "$NIRI_CONFIG"
elif ! grep -q 'include optional=true "appearance.kdl"' "$NIRI_CONFIG"; then
    printf '\ninclude optional=true "appearance.kdl"\n' >> "$NIRI_CONFIG"
fi

# GTK：Shorin 原版 settings.ini 只写 fcitx，主题其实靠 gsettings。
# 这里显式写 gtk-theme-name，保证没有 dconf 时也是 adw-gtk3-dark。
install -Dm644 "$SRC/gtk-3.0/settings.ini" "$HOME_DIR/.config/gtk-3.0/settings.ini"
install -Dm644 "$SRC/gtk-3.0/gtk.css" "$HOME_DIR/.config/gtk-3.0/gtk.css"
install -Dm644 "$SRC/gtk-4.0/settings.ini" "$HOME_DIR/.config/gtk-4.0/settings.ini"
install -Dm644 "$SRC/gtk-4.0/gtk.css" "$HOME_DIR/.config/gtk-4.0/gtk.css"
touch "$HOME_DIR/.config/gtk-3.0/dank-colors.css"
touch "$HOME_DIR/.config/gtk-4.0/dank-colors.css"

# 启动器/终端
install -Dm644 "$SRC/fuzzel/fuzzel.ini" "$HOME_DIR/.config/fuzzel/fuzzel.ini"
install -Dm644 "$SRC/alacritty/alacritty.toml" "$HOME_DIR/.config/alacritty/alacritty.toml"

# Matugen 配置与模板
install -Dm644 "$SRC/matugen/config.toml" "$HOME_DIR/.config/matugen/config.toml"
cp -a "$SRC/matugen/templates/." "$HOME_DIR/.config/matugen/templates/"

# 壁纸
cp -a "$SRC/wallpapers/." "$HOME_DIR/Pictures/Wallpapers/"

chown -R "$USER_NAME:$USER_NAME" \
    "$HOME_DIR/.config/niri" \
    "$HOME_DIR/.config/gtk-3.0" \
    "$HOME_DIR/.config/gtk-4.0" \
    "$HOME_DIR/.config/fuzzel" \
    "$HOME_DIR/.config/alacritty" \
    "$HOME_DIR/.config/matugen" \
    "$HOME_DIR/.local/share/fcitx5/themes/Matugen" \
    "$HOME_DIR/.config/btop" \
    "$HOME_DIR/.config/cava" \
    "$HOME_DIR/Pictures/Wallpapers"

# 首次生成一套颜色；失败不阻断构建，进桌面后换壁纸会重新生成
WALLPAPER="$HOME_DIR/Pictures/Wallpapers/wallhaven-d88d53.png"
if command -v matugen >/dev/null 2>&1 && [[ -f "$WALLPAPER" ]]; then
    runuser -u "$USER_NAME" -- env HOME="$HOME_DIR" \
        matugen image "$WALLPAPER" --mode dark >/dev/null 2>&1 || true
fi
