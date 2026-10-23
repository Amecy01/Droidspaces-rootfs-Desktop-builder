#!/usr/bin/env bash
# 最小外观补丁：只写 niri 布局/动画/blur、Matugen、GTK、fuzzel、alacritty
set -euo pipefail

USER_NAME="${1:?usage: install.sh <username>}"
HOME_DIR="/home/${USER_NAME}"
SRC="/usr/share/droidspaces-appearance"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "需要 root" >&2; exit 1; }
[[ -d "$HOME_DIR" ]] || { echo "用户目录不存在: $HOME_DIR" >&2; exit 1; }

install -d \
    "$HOME_DIR/.config/niri/dms" \
    "$HOME_DIR/.config/gtk-3.0" \
    "$HOME_DIR/.config/gtk-4.0" \
    "$HOME_DIR/.config/fuzzel" \
    "$HOME_DIR/.config/alacritty" \
    "$HOME_DIR/.config/matugen" \
    "$HOME_DIR/.local/share/fcitx5/themes/Matugen" \
    "$HOME_DIR/.local/share/fcitx5/themes/dms" \
    "$HOME_DIR/.local/share/color-schemes" \
    "$HOME_DIR/.local/share/icons" \
    "$HOME_DIR/.config/btop/themes" \
    "$HOME_DIR/.config/cava/themes" \
    "$HOME_DIR/.config/yazi" \
    "$HOME_DIR/.config/fastfetch" \
    "$HOME_DIR/.cache/matugen" \
    "$HOME_DIR/.cache/dms" \
    "$HOME_DIR/Pictures/Wallpapers"

# niri 外观文件；不覆盖 DMS 自己生成的 dms/binds.kdl
for rel in niri/layout.kdl niri/animations.kdl niri/blur.kdl niri/appearance.kdl; do
    install -Dm644 "$SRC/$rel" "$HOME_DIR/.config/$rel"
done

# niri 主配置：没有就建，有就只追加 include，不动 DMS 已有内容
NIRI_CONFIG="$HOME_DIR/.config/niri/config.kdl"
if [[ ! -f "$NIRI_CONFIG" ]]; then
    install -Dm644 "$SRC/niri/config.kdl" "$NIRI_CONFIG"
elif ! grep -qE 'include[[:space:]].*appearance\.kdl' "$NIRI_CONFIG"; then
    printf '\ninclude optional=true "appearance.kdl"\n' >> "$NIRI_CONFIG"
fi

# GTK：Shorin 原版 settings.ini 只写 fcitx，主题其实靠 gsettings。
# 这里显式写 gtk-theme-name，保证没有 dconf 时也是 adw-gtk3-dark。
install -Dm644 "$SRC/gtk-3.0/settings.ini" "$HOME_DIR/.config/gtk-3.0/settings.ini"
install -Dm644 "$SRC/gtk-3.0/gtk.css" "$HOME_DIR/.config/gtk-3.0/gtk.css"
install -Dm644 "$SRC/gtk-4.0/settings.ini" "$HOME_DIR/.config/gtk-4.0/settings.ini"
install -Dm644 "$SRC/gtk-4.0/gtk.css" "$HOME_DIR/.config/gtk-4.0/gtk.css"

# adw-gtk3 在 ALARM 仓库可能不存在；退回到系统自带的 Adwaita-dark
GTK_THEME="adw-gtk3-dark"
if [[ ! -d "/usr/share/themes/${GTK_THEME}" ]]; then
    if [[ -d /usr/share/themes/adw-gtk3 ]]; then
        GTK_THEME="adw-gtk3"
    elif [[ -d /usr/share/themes/Adwaita-dark ]]; then
        GTK_THEME="Adwaita-dark"
    else
        GTK_THEME="Adwaita"
    fi
fi
sed -i "s/^gtk-theme-name=.*/gtk-theme-name=${GTK_THEME}/" \
    "$HOME_DIR/.config/gtk-3.0/settings.ini" \
    "$HOME_DIR/.config/gtk-4.0/settings.ini"

touch "$HOME_DIR/.config/gtk-3.0/dank-colors.css"
touch "$HOME_DIR/.config/gtk-4.0/dank-colors.css"

# 启动器/终端
install -Dm644 "$SRC/fuzzel/fuzzel.ini" "$HOME_DIR/.config/fuzzel/fuzzel.ini"
install -Dm644 "$SRC/alacritty/alacritty.toml" "$HOME_DIR/.config/alacritty/alacritty.toml"

# DMS 会生成 dank-theme.toml；把导入打开，否则 Yazi 会用 Alacritty 默认配色
ALACRITTY_CONFIG="$HOME_DIR/.config/alacritty/alacritty.toml"
if [[ -f "$HOME_DIR/.config/alacritty/dank-theme.toml" ]]; then
    sed -i 's|^# import = .*|import = ["~/.config/alacritty/dank-theme.toml"]|' "$ALACRITTY_CONFIG"
elif [[ -f "$HOME_DIR/.config/alacritty/colors.toml" ]]; then
    sed -i 's|^# import = .*|import = ["~/.config/alacritty/colors.toml"]|' "$ALACRITTY_CONFIG"
fi

# Matugen 配置与模板
install -Dm644 "$SRC/matugen/config.toml" "$HOME_DIR/.config/matugen/config.toml"
install -d "$HOME_DIR/.config/matugen/templates"
cp -a "$SRC/matugen/templates/." "$HOME_DIR/.config/matugen/templates/"

# 壁纸
cp -a "$SRC/wallpapers/." "$HOME_DIR/Pictures/Wallpapers/"

# 整体修正属主：.local 和 .cache 的父目录曾被 install -d 建成 root，
# 导致 DMS 的 matugen 无法创建 color-schemes / fcitx5 themes。
chown -R "$USER_NAME:$USER_NAME" \
    "$HOME_DIR/.config" \
    "$HOME_DIR/.local" \
    "$HOME_DIR/.cache" \
    "$HOME_DIR/Pictures"

# starship 提示符：模板由 Matugen 生成到 ~/.config/starship.toml
if command -v starship >/dev/null 2>&1; then
    if ! grep -q 'starship init bash' "$HOME_DIR/.bashrc"; then
        printf '\n# starship prompt\neval "$(starship init bash)"\n' >> "$HOME_DIR/.bashrc"
    fi
    chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.bashrc"
fi

# 首次生成一套颜色；失败不阻断构建，进桌面后换壁纸会重新生成
WALLPAPER="$HOME_DIR/Pictures/Wallpapers/wallhaven-d88d53.png"
if command -v matugen >/dev/null 2>&1 && [[ -f "$WALLPAPER" ]]; then
    runuser -u "$USER_NAME" -- env HOME="$HOME_DIR" \
        matugen image "$WALLPAPER" --mode dark >/dev/null 2>&1 || true
fi
