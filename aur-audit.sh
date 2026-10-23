#!/usr/bin/env bash
# aur-audit：只审计真正的 AUR 包，不再把 pacman -Qm 里的官方包/第三方包误报成高危。
set -euo pipefail
export LC_ALL=C

RESET=$'\033[0m'; RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; CYA=$'\033[1;36m'
have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || { echo "缺少依赖：$1" >&2; exit 1; }; }

need pacman
need jq
need curl

mapfile -t FOREIGN < <(pacman -Qm 2>/dev/null | awk '{print $1}' | sort)
if ((${#FOREIGN[@]} == 0)); then
    echo "没有 pacman -Qm 列出的 foreign 包。"
    exit 0
fi

if ! compgen -G '/var/lib/pacman/sync/*.db' >/dev/null; then
    echo "${YEL}警告：pacman sync 数据库为空，pacman -Qm 会把大量官方包也列为 foreign。${RESET}" >&2
    echo "      本脚本会用 AUR RPC 再过滤，只审计真正的 AUR 包。" >&2
    echo >&2
fi

# 不能只用 Packager 跳过：AUR 包可以把 Packager 伪造成 Arch Linux。
# 这里全部交给 AUR RPC 判断，AUR 查不到才跳过。
CANDIDATES=("${FOREIGN[@]}")

# 批量查询 AUR RPC，只有 AUR 返回结果的包才进入审计。
declare -A AUR_VERSION AUR_VOTES AUR_MAINT AUR_OUTOF AUR_BASE
CHUNK=100
for ((i = 0; i < ${#CANDIDATES[@]}; i += CHUNK)); do
    args=()
    for pkg in "${CANDIDATES[@]:i:CHUNK}"; do
        args+=(--data-urlencode "arg[]=$pkg")
    done
    rpc=$(curl -fsS --max-time 15 --get "${args[@]}" \
        https://aur.archlinux.org/rpc/v5/info 2>/dev/null || true)
    [[ -n "$rpc" ]] || continue
    while IFS=$'\t' read -r name version votes maint outof base; do
        [[ -n "$name" ]] || continue
        AUR_VERSION["$name"]="$version"
        AUR_VOTES["$name"]="$votes"
        AUR_MAINT["$name"]="$maint"
        AUR_OUTOF["$name"]="$outof"
        AUR_BASE["$name"]="$base"
    done < <(jq -r '.results[]? | [
        .Name,
        (.Version // "-"),
        ((.NumVotes // 0) | tostring),
        (.Maintainer // "(orphan)"),
        (.OutOfDate // "no" | tostring),
        (.PackageBase // .Name)
    ] | @tsv' <<<"$rpc" 2>/dev/null || true)
done

if ((${#AUR_VERSION[@]} == 0)); then
    echo "没有检测到真正的 AUR 包。"
    echo "pacman -Qm 的 ${#FOREIGN[@]} 个 foreign 包里，没有 AUR RPC 返回的包名。"
    exit 0
fi

mapfile -t AUR_PKGS < <(printf '%s\n' "${!AUR_VERSION[@]}" | sort)
mapfile -t AUR_PKGS < <(printf '%s\n' "${AUR_PKGS[@]}" | sed '/^$/d')
if ((${#AUR_PKGS[@]} == 0)); then
    echo "没有检测到真正的 AUR 包。"
    exit 0
fi

printf '%s\n' "${CYA}AUR 包静态审计${RESET}"
printf '已从 %d 个 foreign 包中筛出 %d 个真正的 AUR 包。\n' \
    "${#FOREIGN[@]}" "${#AUR_PKGS[@]}"
printf '说明：启发式检查，不能证明安全；也不能发现构建时已经执行过的恶意行为。\n\n'
printf '%-28s %-12s %-6s %-8s %-8s %s\n' "包名" "版本" "票数" "风险分" "等级" "主要信号"
printf '%s\n' "----------------------------------------------------------------------------------------------------"

TOTAL=0; HIGH=0; MED=0; LOW=0

for pkg in "${AUR_PKGS[@]}"; do
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
        # getcap 只查二进制/库/配置，避免对全部文档执行
        case "$path" in
            /usr/bin/*|/usr/sbin/*|/usr/lib/*|/etc/*)
                if have getcap; then
                    cap=$(getcap "$path" 2>/dev/null || true)
                    [[ -n "$cap" ]] && caps+=("$cap")
                fi ;;
        esac
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
    (( ${#units[@]} )) && { score=$((score + 2)); notes+=("systemd:${#units[@]}"); }
    (( ${#hooks[@]} )) && { score=$((score + 4)); notes+=("pacman-hook:${#hooks[@]}"); }
    (( ${#suders[@]} )) && { score=$((score + 6)); notes+=("sudoers:${#suders[@]}"); }
    (( ${#crons[@]} )) && { score=$((score + 3)); notes+=("cron:${#crons[@]}"); }
    (( ${#profiles[@]} )) && { score=$((score + 2)); notes+=("profile:${#profiles[@]}"); }
    (( ${#preloads[@]} )) && { score=$((score + 8)); notes+=("ld.so.preload"); }

    qkk=$(pacman -Qkk "$pkg" 2>&1 | tail -n 1 | tr -d '\r' || true)
    if [[ "$qkk" == *"0 altered files"* || "$qkk" == *"0 missing files"* ]]; then
        notes+=("files-ok")
    else
        score=$((score + 2))
        notes+=("files-check:${qkk:-unknown}")
    fi

    votes="${AUR_VOTES[$pkg]:-0}"
    maintainer="${AUR_MAINT[$pkg]:-(orphan)}"
    outof="${AUR_OUTOF[$pkg]:-no}"
    base="${AUR_BASE[$pkg]:-$pkg}"

    [[ "$maintainer" == "null" || "$maintainer" == "(orphan)" ]] && {
        score=$((score + 3)); notes+=("orphan");
    }
    [[ "$outof" != "no" && "$outof" != "-" ]] && {
        score=$((score + 1)); notes+=("out-of-date");
    }
    if [[ "$votes" =~ ^[0-9]+$ ]]; then
        (( votes < 1 )) && { score=$((score + 3)); notes+=("votes:0"); }
        (( votes >= 1 && votes < 5 )) && { score=$((score + 1)); notes+=("votes<5"); }
    fi

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

    version=$(pacman -Qi "$pkg" 2>/dev/null | awk -F': ' '/^Version/{print $2; exit}')
    packager=$(pacman -Qi "$pkg" 2>/dev/null | awk -F': ' '/^Packager/{print $2; exit}')
    case "$packager" in
        *"Arch Linux"*|*"Brave Software"*|*"Microsoft"*|*"Google"*)
            score=$((score + 5))
            notes+=("packager:official-name") ;;
    esac

    level="LOW"; color="$GRN"
    if ((score >= 10)); then level="HIGH"; color="$RED"; HIGH=$((HIGH + 1))
    elif ((score >= 5)); then level="MED"; color="$YEL"; MED=$((MED + 1))
    else LOW=$((LOW + 1)); fi

    printf '%-28s %-12s %-6s %-8s %s%-8s%s %s\n' \
        "$pkg" "${version:--}" "$votes" "$score" "$color" "$level" "$RESET" \
        "$(IFS=','; echo "${notes[*]:-none}")"
done

printf '\n%s\n' "----------------------------------------------------------------------------------------------------"
printf 'AUR 包 %d 个：HIGH=%d，MED=%d，LOW=%d\n' "$TOTAL" "$HIGH" "$MED" "$LOW"
cat <<'EOF'

注意：
- pacman sync 数据库被清理过时，pacman -Qm 会把很多官方包也列为 foreign；
  本脚本已用 AUR RPC 过滤，只审计真正能在 AUR 查到的包。
- 这套检查只看安装后的静态痕迹，查不到构建时已经执行过的恶意操作。
- AUR 包在 makepkg 时以你的用户身份执行 PKGBUILD，安装前必须自己读 PKGBUILD/install 脚本。
- 更安全的做法：用干净 chroot 构建（devtools/aurutils），不要用 root 跑 makepkg。
- 高风险信号不等于恶意，低风险也不等于安全。
EOF
