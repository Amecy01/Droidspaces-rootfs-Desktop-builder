#!/usr/bin/env bash
# Arch + niri 的桌面 profile（自定义版）
# 原 scripts/desktops/niri.sh 保留不动，构建时只复制这个文件。
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

desktop=niri
xdg_desktop=niri

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(
        XDG_SESSION_CLASS=user
        XDG_SESSION_TYPE=wayland
        "QT_QPA_PLATFORM=wayland;xcb"
        ANLAND=1
        ANLAND_PRESENT_BACKEND=legacy
        ANLAND_SOCKET=/run/display.sock
        ANLAND_DRM_DEVICE=/dev/dri/renderD128
        ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
        XWAYLAND_GBM_DEVICE=/dev/dri/renderD128
        MESA_LOADER_DRIVER_OVERRIDE=kgsl
        GALLIUM_DRIVER=kgsl
        FD_FORCE_KGSL=1
        MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1
        FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "$desktop 显示后端无效：$backend" >&2
        return 1
    }
    assignments+=("XDG_CURRENT_DESKTOP=$xdg_desktop" "XDG_SESSION_DESKTOP=$xdg_desktop")
    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        grep -q "^${key}=" "$environment_file" || printf '%s\n' "$assignment" >> "$environment_file"
    done
}

install_niri_arch() {
    # 必需组件
    pacman -S --noconfirm --needed \
        xdg-desktop-portal xdg-desktop-portal-gtk xdg-utils \
        alacritty fuzzel mako waybar swaybg swaylock wl-clipboard \
        brightnessctl playerctl \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        mesa-utils vulkan-tools wayland-utils \
        xdg-user-dirs \
        polkit polkit-gnome \
        qt5-wayland qt6-wayland \
        gst-plugins-base gst-plugins-good \
        noto-fonts noto-fonts-cjk noto-fonts-emoji

    # 可选：仓库里没有就跳过，不阻断构建
    pacman -S --noconfirm --needed gst-plugin-va 2>/dev/null || true
    pacman -S --noconfirm --needed libva-utils 2>/dev/null || true
}

install_profile() {
    case "$ID:${VERSION_ID:-}" in
        arch:*|archarm:*|archlinux:*) install_niri_arch ;;
        *)
            echo "$desktop 只支持 Arch Linux ARM，当前：$ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "$desktop profile 操作无效：$1" >&2; exit 1 ;;
esac
