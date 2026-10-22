# ogarcia/archlinux 基础 arch 镜像（Arch + niri + Anland，只支持 anland-wayland）
FROM ogarcia/archlinux AS customizer

#######################################################
ARG USERNAME
ARG PASSWORD
ARG ANLAND_RELEASE_REPOSITORY=Goldzxcbug/droidspaces-package
ARG ANLAND_PACKAGE_REVISION=unknown
######################################################

# 复制全部所需脚本（niri profile 用自定义的 my_niri.sh）
COPY scripts/tui/install-anland-niri.sh /usr/local/sbin/install-anland-niri
COPY my_niri.sh /usr/local/lib/droidspaces/desktops/niri.sh
COPY scripts/configure-desktop.sh /usr/local/sbin/configure-desktop
COPY scripts/tui/install-mesa.sh /usr/local/sbin/install-mesa
COPY scripts/etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf /tmp/Anland-Audio.conf
COPY scripts/install-usb-manager.sh /usr/local/sbin/install-droidspaces-usb-manager
COPY scripts/start-desktop-session.sh /usr/local/bin/start-desktop-session

# 更换加速镜像源（heredoc 用引号，保留 $repo 给 pacman 替换）
RUN tee /etc/pacman.d/mirrorlist >/dev/null <<'EOF'
# Arch Linux ARM repository mirrorlist
Server = https://mirrors.ustc.edu.cn/archlinuxarm/aarch64/$repo
Server = https://mirrors.aliyun.com/archlinuxarm/aarch64/$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/aarch64/$repo
Server = https://mirror.sjtu.edu.cn/archlinuxarm/aarch64/$repo
Server = https://mirrors.bfsu.edu.cn/archlinuxarm/aarch64/$repo
Server = http://mirror.archlinuxarm.org/aarch64/$repo
EOF

# 添加 CN 仓库
RUN tee -a /etc/pacman.conf >/dev/null <<'EOF'

[archlinuxcn]
Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
Server = https://mirrors.aliyun.com/archlinuxcn/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
EOF

# 安装声音配置文件
RUN install -D -m 0644 /tmp/Anland-Audio.conf /etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf && \
    rm -f /tmp/Anland-Audio.conf

# 执行权限 + 打开并行下载、放开语言包
RUN chmod +x \
        /usr/local/sbin/install-anland-niri \
        /usr/local/sbin/install-mesa \
        /usr/local/sbin/configure-desktop \
        /usr/local/sbin/install-droidspaces-usb-manager \
        /usr/local/bin/start-desktop-session \
        /usr/local/lib/droidspaces/desktops/niri.sh && \
    sed -i '/^#ParallelDownloads/s/^#//' /etc/pacman.conf && \
    sed -i '/NoExtract.*locale/d' /etc/pacman.conf && \
    sed -i '/NoExtract.*i18n/d' /etc/pacman.conf

# keyring：先装 Arch/ARM 的钥匙，再装 CN 的钥匙，最后统一 populate
RUN pacman -Sy --noconfirm archlinux-keyring archlinuxarm-keyring glibc && \
    pacman -Su --noconfirm && \
    { [ -d /etc/pacman.d/gnupg ] || pacman-key --init; } && \
    pacman-key --populate archlinux archlinuxarm && \
    pacman -S --noconfirm --needed archlinuxcn-keyring && \
    pacman-key --populate archlinuxcn

# 基础工具
RUN pacman -S --noconfirm --needed \
        bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates \
        bash-completion dbus systemd pam fastfetch logrotate \
        git nano sudo \
        openssh net-tools iptables iputils iproute2 bind \
        procps-ng \
        libarchive kmod tzdata tar

# niri 的周边组件（profile 自带 install 参数）
RUN /usr/local/lib/droidspaces/desktops/niri.sh install

# 输入法
RUN pacman -S --noconfirm --needed fcitx5-im fcitx5-chinese-addons

# 压缩工具
RUN pacman -S --noconfirm --needed zip unzip p7zip bzip2 xz tar gzip

# 从固定滚动 GitHub Release 安装 Anland niri（Arch 只支持 anland-wayland）
RUN echo "--> [enabled] Installing Anland niri packages (${ANLAND_PACKAGE_REVISION})..." && \
    ANLAND_RELEASE_REPOSITORY="${ANLAND_RELEASE_REPOSITORY}" \
    ANLAND_NIRI_RELEASE_REPOSITORY="${ANLAND_RELEASE_REPOSITORY}" \
    /usr/local/sbin/install-anland-niri --1 && \
    echo "--> [enabled] Anland niri support installed"

# 配置 Locale 与 SSH
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen && \
    locale-gen && \
    echo "LANG=zh_CN.UTF-8" > /etc/locale.conf && \
    mkdir -p /var/run/sshd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    (userdel -r alarm 2>/dev/null || true) && \
    useradd -m -s /bin/bash "${USERNAME}" && \
    printf '%s:%s\n' "${USERNAME}" "${PASSWORD}" | chpasswd && \
    systemctl enable sshd

# Droidspaces USB Manager
RUN /usr/local/sbin/install-droidspaces-usb-manager --user "${USERNAME}"

# 为 droidspaces 的 su/su -l 入口建立完整的 systemd 用户会话。
RUN for pam_file in /etc/pam.d/su /etc/pam.d/su-l; do \
        if ! grep -qE '^[[:space:]-]*session[[:space:]].*pam_systemd\.so' "$pam_file"; then \
            sed -i '/^[[:space:]]*session[[:space:]].*pam_unix\.so/a\session        optional        pam_systemd.so' "$pam_file"; \
        fi; \
    done && \
    grep -qE '^[[:space:]]*session[[:space:]].*pam_env\.so' /etc/pam.d/su-l || \
        echo 'session        required        pam_env.so' >> /etc/pam.d/su-l

# 初始化环境变量文件；桌面专属变量由 profile 管理
RUN : > /etc/environment

# Anland 后端的 GPU 驱动环境变量
RUN echo 'MESA_LOADER_DRIVER_OVERRIDE=kgsl' >> /etc/environment && \
    echo 'GALLIUM_DRIVER=kgsl' >> /etc/environment && \
    echo 'FD_FORCE_KGSL=1' >> /etc/environment && \
    echo 'FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1' >> /etc/environment

# 输入法自启、会话环境、桌面配置
COPY scripts/start/ /tmp/droidspaces-start/
RUN <<'EOF_RUN'
    set -e
    mkdir -p "/home/${USERNAME}/.config/autostart"
    cat <<'EOF' > "/home/${USERNAME}/.config/autostart/fcitx5.desktop"
[Desktop Entry]
Name=Fcitx5
GenericName=Input Method
Comment=Start Input Method
Exec=fcitx5 -d
Icon=fcitx
Terminal=false
Type=Application
Categories=System;Utility;
StartupNotify=false
NoDisplay=true
EOF
    cat <<'EOF' >> /etc/environment
XMODIFIERS=@im=fcitx5
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
SDL_IM_MODULE=fcitx5
GLFW_IM_MODULE=fcitx
EOF

    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> "/home/${USERNAME}/.bashrc"
    /usr/local/sbin/configure-desktop "niri" "anland-wayland" "true" "${USERNAME}"
    rm -rf /tmp/droidspaces-start
EOF_RUN

# 下载并安装 Mesa
RUN /usr/local/sbin/install-mesa --1

# 修复容器内的 DHCP 网络服务配置
RUN mkdir -p /etc/systemd/network && \
    cat <<'EOF' > /etc/systemd/network/10-eth-dhcp.network
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOF

# 应用 Android 运行环境兼容性修复（重点针对 Systemd 和 Udev）
RUN <<'EOF_RUN'
# --- 1. 常规兼容性修复 ---
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu
usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,wheel,droidspaces-gpu "${USERNAME}" || true

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- 2. 针对 Systemd 的特定修复 ---
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

cat >> /etc/systemd/journald.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

mkdir -p /etc/systemd/system/multi-user.target.wants
GUEST_SYSTEMD_PATH="/usr/lib/systemd/system"

if [ -f "$GUEST_SYSTEMD_PATH/dbus.service" ]; then
    ln -sf "$GUEST_SYSTEMD_PATH/dbus.service" "/etc/systemd/system/multi-user.target.wants/dbus.service"
fi

for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
        ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
    fi
done

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
EOF
    fi
done

for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-hwaccess-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q 'enable_hw_access=1' /run/droidspaces/container.config"
EOF
    fi
done

if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# 清理：构建期脚本、TUI、缓存、日志、临时目录、machine-id、SSH host key
RUN rm -f \
        /usr/local/sbin/configure-desktop \
        /usr/local/sbin/install-anland-niri \
        /usr/local/sbin/install-mesa \
        /usr/local/sbin/install-droidspaces-usb-manager \
        /usr/local/bin/droidspaces-tui \
        /usr/local/bin/dstui \
        /var/log/pacman.log && \
    rm -rf /usr/local/lib/droidspaces/desktops \
        /var/cache/pacman/pkg/* \
        /var/lib/pacman/sync/* \
        /tmp/* \
        /root/.cache \
        /var/lib/systemd/random-seed && \
    : > /etc/machine-id && \
    rm -f /etc/ssh/ssh_host_*

FROM scratch AS export
COPY --from=customizer / /
