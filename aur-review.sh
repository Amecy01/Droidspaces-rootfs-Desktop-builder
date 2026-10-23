#!/usr/bin/env bash
# aur-review：安装前审阅 AUR 包的 PKGBUILD / .install。
# 只做静态检查，不执行 PKGBUILD；确认后可选调用 yay/paru 安装。
set -euo pipefail

RESET=$'\033[0m'; RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; CYA=$'\033[1;36m'
DO_INSTALL=0
PKG=""

usage() {
    cat <<'EOF'
用法:
  aur-review <包名>              只审阅，不安装
  aur-review --install <包名>    审阅后询问是否安装

示例:
  aur-review brave-bin
  aur-review --install brave-bin
EOF
}

while (($#)); do
    case "$1" in
        --install|-i) DO_INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "未知参数: $1" >&2; usage; exit 2 ;;
        *) PKG="$1"; shift ;;
    esac
done

[[ -n "$PKG" ]] || { usage; exit 2; }
[[ ${EUID:-$(id -u)} -ne 0 ]] || { echo "请不要用 root 运行 aur-review；makepkg 必须以普通用户执行。" >&2; exit 1; }
for c in git curl jq; do command -v "$c" >/dev/null 2>&1 || { echo "缺少依赖: $c" >&2; exit 1; }; done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "${CYA}==> 查询 AUR: ${PKG}${RESET}"
rpc="$(curl -fsS --max-time 10 --get --data-urlencode "arg[]=${PKG}" \
    https://aur.archlinux.org/rpc/v5/info 2>/dev/null || true)"
base="$PKG"
if [[ -n "$rpc" ]] && jq -e '.results[0]' >/dev/null 2>&1 <<<"$rpc"; then
    base="$(jq -r '.results[0].PackageBase // empty' <<<"$rpc")"
    [[ -n "$base" ]] || base="$PKG"
    echo "维护者: $(jq -r '.results[0].Maintainer // "orphan"' <<<"$rpc")"
    echo "票数:   $(jq -r '.results[0].NumVotes // 0' <<<"$rpc")"
    echo "过期:   $(jq -r '.results[0].OutOfDate // "no"' <<<"$rpc")"
else
    echo "${YEL}警告: AUR RPC 无结果或不可用，按包名直接 clone。${RESET}"
fi

echo
echo "${CYA}==> 下载 PKGBUILD（不执行）${RESET}"
if ! git clone --depth 1 "https://aur.archlinux.org/${base}.git" "$tmp/$base" >/dev/null 2>&1; then
    echo "无法下载 https://aur.archlinux.org/${base}.git" >&2
    exit 1
fi

pkgbuild="$tmp/$base/PKGBUILD"
[[ -f "$pkgbuild" ]] || { echo "没有 PKGBUILD" >&2; exit 1; }

echo "目录: $tmp/$base"
score=0
flag() { score=$((score + $1)); printf '  %s%s%s\n' "$YEL" "$2" "$RESET"; }

# 先看架构，避免 makepkg 到最后才报 “不支持 aarch64”
srcinfo="$tmp/$base/.SRCINFO"
if [[ -f "$srcinfo" ]]; then
    arch_line="$(grep -E '^[[:space:]]*arch[[:space:]]*=' "$srcinfo" | head -1 || true)"
    echo "架构:   ${arch_line#*=}"
    if ! grep -qE '^[[:space:]]*arch[[:space:]]*=.*(any|aarch64|arm64)' "$srcinfo"; then
        flag 10 "PKGBUILD 的 arch 不包含 aarch64/any，ARM64 上无法构建"
    fi
    if grep -qE '^[[:space:]]*source_x86_64' "$srcinfo" &&
       ! grep -qE '^[[:space:]]*source_aarch64|^[[:space:]]*source_arm64' "$srcinfo"; then
        flag 4 "只有 x86_64 的 source，没有 aarch64/arm64 source"
    fi
else
    arch_line="$(grep -E '^[[:space:]]*arch[[:space:]]*=' "$pkgbuild" | head -1 || true)"
    echo "架构:   ${arch_line#*=}"
    if ! grep -qE '^[[:space:]]*arch[[:space:]]*=.*(any|aarch64|arm64)' "$pkgbuild"; then
        flag 10 "PKGBUILD 的 arch 不包含 aarch64/any，ARM64 上无法构建"
    fi
fi

echo
echo "${CYA}==> source / 校验${RESET}"
grep -nE '^[[:space:]]*(source|sha256sums|sha512sums|b2sums|md5sums)' "$pkgbuild" || true

echo
echo "${CYA}==> 风险模式${RESET}"

if grep -qiE '(curl|wget)[^#]*\|[[:space:]]*(ba)?sh' "$pkgbuild"; then
    flag 6 "网络脚本直接执行: curl/wget | sh"
fi
if grep -qiE 'base64[[:space:]]+-d|/dev/tcp|nc[[:space:]]+-e' "$pkgbuild"; then
    flag 5 "混淆/反弹 shell 特征: base64 -d、/dev/tcp、nc -e"
fi
if grep -qiE 'chmod[[:space:]]+[46][0-7]{3}|chmod[[:space:]]+\+s' "$pkgbuild"; then
    flag 4 "setuid/setgid: chmod 4755/+s"
fi
if grep -qiE 'systemctl[[:space:]]+(enable|start)|useradd|visudo|sudoers|pacman[[:space:]]+-U' "$pkgbuild"; then
    flag 4 "修改系统: systemctl/useradd/sudoers/pacman -U"
fi
if grep -qE '^[[:space:]]*(pre|post)_(install|upgrade|remove)[[:space:]]*\(' "$pkgbuild"; then
    flag 3 "包含 install 脚本函数"
fi
if grep -qE "SKIP" "$pkgbuild"; then
    flag 3 "校验和含 SKIP"
fi
if grep -qE '^source.*(http://|ftp://)' "$pkgbuild"; then
    flag 2 "source 使用明文 HTTP/FTP"
fi
if grep -qiE '(^|[[:space:]])rm[[:space:]]+-rf[[:space:]]+/' "$pkgbuild"; then
    flag 5 "包含 rm -rf / 路径"
fi

for f in "$tmp/$base"/*.install; do
    [[ -f "$f" ]] || continue
    echo "  ${YEL}发现 .install: $(basename "$f")${RESET}"
    grep -nE 'curl|wget|base64|/dev/tcp|chmod|systemctl|useradd|rm -rf|sudo' "$f" || true
    score=$((score + 2))
done

echo
if ((score >= 10)); then
    level="HIGH"; color="$RED"
elif ((score >= 5)); then
    level="MED"; color="$YEL"
else
    level="LOW"; color="$GRN"
fi
printf '风险分: %s%s%s (%s)\n' "$color" "$score" "$RESET" "$level"

echo
echo "${CYA}==> PKGBUILD 关键段${RESET}"
sed -n '/^[[:space:]]*build[[:space:]]*()/,/^}/p' "$pkgbuild" | head -80 || true
echo "---- package() ----"
sed -n '/^[[:space:]]*package[[:space:]]*()/,/^}/p' "$pkgbuild" | head -80 || true

echo
echo "完整 PKGBUILD: $pkgbuild"
echo "请自行确认 source、build()、package() 和 .install 后再安装。"

if ((DO_INSTALL)); then
    if command -v paru >/dev/null 2>&1; then
        helper=paru
    elif command -v yay >/dev/null 2>&1; then
        helper=yay
    else
        echo "没有找到 yay/paru，无法自动安装。" >&2
        exit 1
    fi
    read -r -p "确认安装 ${PKG}? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "已取消。"; exit 0; }
    exec "$helper" -S --needed "$PKG"
else
    echo
    echo "只审阅，未安装。确认无误后运行："
    echo "  yay -S $PKG"
    echo "或："
    echo "  paru -S $PKG"
fi
