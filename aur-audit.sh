#!/usr/bin/env bash
# aur-audit：对已安装的非官方包（AUR / 第三方仓库）做静态风险体检。
# 只读检查，不执行包内程序；不能替代“安装前读 PKGBUILD”。
set -euo pipefail

RESET=$'\033[0m'; RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; CYA=$'\033[1;36m'

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || { echo "缺少依赖：$1" >&2; exit 1; }; }

need pacman
need jq
need curl

mapfile -t PKGS < <(pacman -Qm 2>/dev/null | awk '{print $1}' | sort)
if ((${#PKGS[@]} == 0)); then
    echo "没有 pacman -Qm 列出的非官方包。"
    exit 0
fi

printf '%s\n' "${CYA}非官方包静态审计${RESET}"
printf '说明：这是基于文件、pacman 元数据和 AUR RPC/PKGBUILD 的启发式检查，'
printf '不能证明包安全，也不能发现构建时已经执行过的恶意行为。\n\n'
printf '%-28s %-12s %-6s %-8s %-8s %s\n' "包名" "版本" "票数" "风险分" "等级" "主要信号"
printf '%s\n' "----------------------------------------------------------------------------------------------------"

TOTAL=0; HIGH=0; MED=0; LOW=0

for pkg in "${PKGS[@]}"; do
    TOTAL=$((TOTAL + 1))
    score=0
    notes=()
    files=()

    while IFS= read -r line; do
        files+=("${line#* }")
    done < <(pacman -Ql "$pkg" 2>/dev/null | awk 'NF>=2 {print $1" "$2}')

    setuid=(); caps=(); units=(); hooks=(); suders=(); crons=(); profiles=(); preloads=()
    for path in "${files[@]}"; do
        [[ -e "$path" ]] || continue
        if find "$path" -maxdepth 0 -perm /6000 -print -quit 2>/dev/null | grep -q .; then
            setuid+=("$path")
        fi
        if have getcap; then
            cap=$(getcap "$path" 2>/dev/null || true)
            [[ -n "$cap" ]] && caps+=("$cap")
        fi
        case "$path" in
            /etc/systemd/system/*|/usr/lib/systemd/system/*|/usr/lib/systemd/user/*)
                units+=("$path") ;;
            /etc/pacman.d/hooks/*|/usr/share/libalpm/hooks/*)
                hooks+=("$path") ;;
            /etc/sudoers.d/*)
                suders+=("$path") ;;
            /etc/cron*|/var/spool/cron/*)
                crons+=("$path") ;;
            /etc/profile.d/*|/etc/bash.bashrc|/etc/profile)
                profiles+=("$path") ;;
            /etc/ld.so.preload)
                preloads+=("$path") ;;
        esac
    done

    (( ${#setuid[@]} )) && { score=$((score + 6)); notes+=("setuid/setgid:${#setuid[@]}"); }
    (( ${#caps[@]} )) && { score=$((score + 4)); notes+=("capabilities:${#caps[@]}"); }
    (( ${#units[@]} )) && { score=$((score + 3)); notes+=("systemd:${#units[@]}"); }
    (( ${#hooks[@]} )) && { score=$((score + 5)); notes+=("pacman-hook:${#hooks[@]}"); }
    (( ${#suders[@]} )) && { score=$((score + 6)); notes+=("sudoers:${#suders[@]}"); }
    (( ${#crons[@]} )) && { score=$((score + 3)); notes+=("cron:${#crons[@]}"); }
    (( ${#profiles[@]} )) && { score=$((score + 2)); notes+=("profile:${#profiles[@]}"); }
    (( ${#preloads[@]} )) && { score=$((score + 8)); notes+=("ld.so.preload"); }

    # 包文件完整性（pacman 的 mtree 校验）
    qkk=$(pacman -Qkk "$pkg" 2>&1 | tail -n 1 | tr -d '\r' || true)
    if [[ "$qkk" == *"0 altered files"* || "$qkk" == *"0 missing files"* ]]; then
        notes+=("files-ok")
    else
        score=$((score + 2))
        notes+=("files-check:${qkk:-unknown}")
    fi

    # AUR 元数据
    votes="-"; maintainer="-"; outofdate="-"; base="$pkg"
    rpc=$(curl -fsS --max-time 8 --get --data-urlencode "arg[]=$pkg" \
        https://aur.archlinux.org/rpc/v5/info 2>/dev/null || true)
    if [[ -n "$rpc" ]]; then
        votes=$(jq -r '.results[0].NumVotes // "-"' <<<"$rpc" 2>/dev/null || echo "-")
        maintainer=$(jq -r '.results[0].Maintainer // "(orphan)"' <<<"$rpc" 2>/dev/null || echo "-")
        outofdate=$(jq -r '.results[0].OutOfDate // "no"' <<<"$rpc" 2>/dev/null || echo "-")
        base=$(jq -r '.results[0].PackageBase // empty' <<<"$rpc" 2>/dev/null || true)
        [[ -n "$base" ]] || base="$pkg"
        [[ "$maintainer" == "null" ]] && maintainer="(orphan)"
        [[ "$maintainer" == "(orphan)" ]] && { score=$((score + 3)); notes+=("orphan"); }
        [[ "$outofdate" != "no" && "$outofdate" != "-" ]] && { score=$((score + 1)); notes+=("out-of-date"); }
        if [[ "$votes" =~ ^[0-9]+$ ]]; then
            (( votes < 1 )) && { score=$((score + 3)); notes+=("votes:0"); }
            (( votes >= 1 && votes < 5 )) && { score=$((score + 1)); notes+=("votes<5"); }
        fi
    else
        notes+=("aur-rpc:unavailable")
    fi

    # PKGBUILD 静态检查
    if [[ "$base" != "-" && -n "$base" ]]; then
        pkgbuild=$(curl -fsS --max-time 10 \
            "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=${base}" 2>/dev/null || true)
        if [[ -n "$pkgbuild" ]]; then
            if grep -qiE '(curl|wget)[^#]*\|[[:space:]]*(ba)?sh' <<<"$pkgbuild"; then
                score=$((score + 5)); notes+=("PKGBUILD:curl|sh")
            fi
            if grep -qiE 'base64[[:space:]]+-d|/dev/tcp|nc[[:space:]]+-e' <<<"$pkgbuild"; then
                score=$((score + 4)); notes+=("PKGBUILD:obfuscation")
            fi
            if grep -qiE 'chmod[[:space:]]+[46][0-7]{3}|chmod[[:space:]]+\+s' <<<"$pkgbuild"; then
                score=$((score + 3)); notes+=("PKGBUILD:setuid")
            fi
            if grep -qiE 'systemctl[[:space:]]+(enable|start)|useradd|visudo|sudoers' <<<"$pkgbuild"; then
                score=$((score + 2)); notes+=("PKGBUILD:system-change")
            fi
            if grep -qE '^[[:space:]]*(pre|post)_(install|upgrade|remove)\(' <<<"$pkgbuild"; then
                score=$((score + 2)); notes+=("PKGBUILD:install-script")
            fi
            if grep -qE "SKIP" <<<"$pkgbuild"; then
                score=$((score + 2)); notes+=("PKGBUILD:SKIP-sum")
            fi
            if grep -qE '^source.*(http://|ftp://)' <<<"$pkgbuild"; then
                score=$((score + 1)); notes+=("PKGBUILD:plain-http")
            fi
        else
            notes+=("PKGBUILD:unavailable")
        fi
    fi

    level="LOW"; color="$GRN"
    if ((score >= 10)); then level="HIGH"; color="$RED"; HIGH=$((HIGH + 1))
    elif ((score >= 5)); then level="MED"; color="$YEL"; MED=$((MED + 1))
    else LOW=$((LOW + 1)); fi

    version=$(pacman -Qi "$pkg" 2>/dev/null | awk -F': ' '/^Version/{print $2; exit}')
    printf '%-28s %-12s %-6s %-8s %s%-8s%s %s\n' \
        "$pkg" "${version:--}" "$votes" "$score" "$color" "$level" "$RESET" \
        "$(IFS=','; echo "${notes[*]:-none}")"
done

printf '\n%s\n' "----------------------------------------------------------------------------------------------------"
printf '共 %d 个非官方包：HIGH=%d，MED=%d，LOW=%d\n' "$TOTAL" "$HIGH" "$MED" "$LOW"
cat <<'EOF'

注意：
- 这只能检查“安装后留下的静态痕迹”，查不到构建时已经执行过的恶意操作。
- AUR 包在 makepkg 时以你的用户身份执行 PKGBUILD，必须在安装前阅读 PKGBUILD/install 脚本。
- 更安全的做法：用干净 chroot 构建（devtools/aurutils），不要用 root 跑 makepkg。
- 高风险信号不等于恶意，低风险也不等于安全。
EOF
