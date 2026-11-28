#!/usr/bin/env bash
# chaos.sh —— 盲盒故障注入器（6 类题库，每类带注入自检与对称恢复）
#
# 设计约束（这三条决定了它能不能用来做训练）：
#   1. 注入必须有自检：注入完自己验一遍，验不过就自动回退，绝不留下"看起来注入了"的状态
#   2. 恢复必须与注入严格对称：少一项，下一轮现象叠加；多一项，可能改坏基线
#   3. 答案必须隔离：/root/.chaos 权限 700、答案文件 600，排查期间不许看
#
# 三段分离：do_inject（改状态）→ verify_one（只读判断）→ do_restore（改回来）
# --status 只调 verify_one，绝不会二次注入。
#
# 用法：
#   sudo ./chaos.sh --list            列出题库
#   sudo ./chaos.sh --inject 4        随机注入 4 个（互不重复）
#   sudo ./chaos.sh --status          查看当前注入了什么、每条是否仍然成立
#   sudo ./chaos.sh --answer          查看本轮答案（排查结束后才允许）
#   sudo ./chaos.sh --restore         按答案逐项恢复，可重复执行
#
# 环境变量：CHAOS_DIR（默认 /root/.chaos）、CHAOS_LOG_MB（默认 500）、CHAOS_SITE
# 退出码：0 成功 / 1 用法或权限错误 / 2 有注入项自检失败已回退

set -u

ANS_DIR=${CHAOS_DIR:-/root/.chaos}
ANS="$ANS_DIR/answer.txt"
LOG_MB=${CHAOS_LOG_MB:-500}
SITE=${CHAOS_SITE:-/var/www/html}
INDEX="$SITE/index.nginx-debian.html"
MARK='chaos-injected'
FAULTS=(log_flood port_busy perm_denied ssh_down dns_bad hosts_wrong)

c_ok()   { printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
c_bad()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m[..]\033[0m   %s\n' "$*"; }

require_root() {
    [ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行" >&2; exit 1; }
}

iface() {
    local i
    i=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    [ -n "$i" ] || i=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    printf '%s' "$i"
}

# 端口是否处于 LISTEN。awk 读完整个输入，避免 grep -q 提前退出造成 SIGPIPE 误判
has_listen() {
    ss -lntH 2>/dev/null | awk -v want=":$1" '$4 ~ (want "$") {found=1} END{exit !found}'
}

listen_owner() {
    ss -lntpH "sport = :$1" 2>/dev/null | head -1 | sed -n 's/.*users:((\([^,]*\).*/\1/p'
}

http_code() {
    curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1/" 2>/dev/null || echo 000
}

syslog_mb() {
    local v
    v=$(du -m /var/log/syslog 2>/dev/null | awk '{print $1}')
    printf '%s' "${v:-0}"
}

unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

# ---------- 前置条件：环境不具备就跳过，不制造"恒真自检" ----------
precheck() {
    case "$1" in
    log_flood)   [ -w /var/log/syslog ] || { echo "syslog 不可写"; return 1; };;
    port_busy)   command -v python3 >/dev/null || { echo "缺 python3"; return 1; }
                 unit_exists nginx.service || { echo "本机没有 nginx 单元"; return 1; };;
    perm_denied) [ -f "$INDEX" ] || { echo "缺少自检锚点文件 $INDEX"; return 1; }
                 command -v curl >/dev/null || { echo "缺 curl，无法用状态码自检"; return 1; };;
    ssh_down)    unit_exists ssh.service || { echo "本机没有 ssh 单元"; return 1; };;
    dns_bad)     command -v resolvectl >/dev/null || { echo "缺 resolvectl"; return 1; }
                 getent hosts www.ubuntu.com >/dev/null 2>&1 \
                     || { echo "断网环境：解析本来就失败，注入无意义"; return 1; };;
    hosts_wrong) [ -w /etc/hosts ] || { echo "/etc/hosts 不可写"; return 1; }
                 getent hosts www.ubuntu.com >/dev/null 2>&1 \
                     || { echo "断网环境：解析本来就失败，注入无意义"; return 1; };;
    *) return 1;;
    esac
}

# ---------- 改状态 ----------
do_inject() {
    local f=$1 i
    case "$f" in
    log_flood)
        # 先留原件：truncate 会连真实日志一起丢掉，回滚要靠这份备份
        [ -f "$ANS_DIR/syslog.bak" ] || cp -p /var/log/syslog "$ANS_DIR/syslog.bak" 2>/dev/null
        yes 'chaos: engine failed' 2>/dev/null | head -c "${LOG_MB}M" >> /var/log/syslog
        ;;
    port_busy)
        systemctl stop nginx >/dev/null 2>&1
        setsid nohup python3 -m http.server 80 --directory "$SITE" >/dev/null 2>&1 &
        for i in 1 2 3 4 5; do sleep 1; has_listen 80 && break; done
        ;;
    perm_denied)
        chmod 700 "$SITE"
        ;;
    ssh_down)
        # ubuntu24 是 socket 激活：只 stop ssh.service，22 端口仍在 systemd 手里
        if unit_exists ssh.socket; then
            systemctl stop ssh.socket ssh.service >/dev/null 2>&1
        else
            systemctl stop ssh >/dev/null 2>&1
        fi
        ;;
    dns_bad)
        resolvectl dns "$(iface)" 10.255.255.1 >/dev/null 2>&1
        resolvectl flush-caches >/dev/null 2>&1
        ;;
    hosts_wrong)
        printf '127.0.0.1 www.ubuntu.com # %s\n' "$MARK" >> /etc/hosts
        ;;
    esac
}

# ---------- 只读校验：--status 与注入自检共用 ----------
verify_one() {
    local f=$1
    case "$f" in
    log_flood)   [ "$(syslog_mb)" -ge $((LOG_MB * 9 / 10)) ];;
    port_busy)   has_listen 80 && listen_owner 80 | grep -q python3;;
    perm_denied) [ "$(http_code)" = "403" ];;
    ssh_down)    ! has_listen 22;;
    dns_bad)     ! timeout 3 getent hosts www.ubuntu.com >/dev/null 2>&1;;
    hosts_wrong) getent hosts www.ubuntu.com 2>/dev/null | grep -q '^127\.0\.0\.1' \
                     && grep -q "# $MARK\$" /etc/hosts;;
    *) return 1;;
    esac
}

# ---------- 改回来 ----------
do_restore() {
    local f=$1
    case "$f" in
    log_flood)
        if [ -f "$ANS_DIR/syslog.bak" ]; then
            cat "$ANS_DIR/syslog.bak" > /var/log/syslog   # 保留 inode，rsyslog 无需重开
            rm -f "$ANS_DIR/syslog.bak"
        elif [ "$(syslog_mb)" -ge "$LOG_MB" ]; then
            truncate -s 0 /var/log/syslog                # 无备份时才截断，且只在确实变大时
        fi
        ;;
    port_busy)
        pkill -f 'http.server 80' >/dev/null 2>&1
        sleep 1
        systemctl start nginx >/dev/null 2>&1
        ;;
    perm_denied)
        chmod 755 "$SITE"
        ;;
    ssh_down)
        if unit_exists ssh.socket; then
            systemctl start ssh.socket >/dev/null 2>&1
        else
            systemctl start ssh >/dev/null 2>&1
        fi
        ;;
    dns_bad)
        resolvectl revert "$(iface)" >/dev/null 2>&1
        resolvectl flush-caches >/dev/null 2>&1
        ;;
    hosts_wrong)
        sed -i "\|# $MARK\$|d" /etc/hosts
        ;;
    esac
    return 0
}

# ---------- 无重复抽取的洗牌 ----------
pick_faults() {
    local n=$1 i j tmp
    local pool=("${FAULTS[@]}")
    for ((i = ${#pool[@]} - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        tmp=${pool[i]}; pool[i]=${pool[j]}; pool[j]=$tmp
    done
    printf '%s\n' "${pool[@]:0:n}"
}

# ---------- 主程序 ----------
cmd=${1:-}
require_root
mkdir -p "$ANS_DIR"; chmod 700 "$ANS_DIR"

case "$cmd" in
--list)
    printf '%s\n' "${FAULTS[@]}"
    ;;

--inject)
    n=${2:-1}
    case "$n" in ''|*[!0-9]*) echo "注入数量必须是正整数" >&2; exit 1;; esac
    [ "$n" -ge 1 ] && [ "$n" -le ${#FAULTS[@]} ] || { echo "数量必须在 1..${#FAULTS[@]}" >&2; exit 1; }
    : > "$ANS"; chmod 600 "$ANS"
    injected=0; failed=0
    while read -r f; do
        [ "$injected" -ge "$n" ] && break
        [ -z "$f" ] && continue
        if ! precheck "$f"; then
            c_info "$f 前置条件不满足，跳过"
            continue
        fi
        do_inject "$f"
        if verify_one "$f"; then
            injected=$((injected + 1))
            printf '%s #%d %s\n' "$(date '+%F %T')" "$injected" "$f" >> "$ANS"
            c_ok "$f 注入成功（自检通过）"
        else
            failed=$((failed + 1))
            do_restore "$f"
            c_bad "$f 自检失败，已自动回退"
        fi
    done < <(pick_faults "${#FAULTS[@]}")

    echo
    echo "已注入 $injected 个故障，答案在 $ANS（排查期间不许看）"
    [ "$failed" -gt 0 ] && echo "另有 $failed 个因自检失败被回退，本轮不计入" >&2
    [ "$injected" -eq 0 ] && exit 2
    ;;

--status)
    [ -s "$ANS" ] || { echo "当前没有注入记录"; exit 0; }
    while read -r d t no f; do
        [ -n "${f:-}" ] || continue
        if verify_one "$f"; then
            printf '%s %s  %-12s 现象仍在\n' "$d" "$t" "$f"
        else
            printf '%s %s  %-12s 现象已消失（可能被手工改回或未生效）\n' "$d" "$t" "$f"
        fi
    done < "$ANS"
    ;;

--answer)
    [ -s "$ANS" ] || { echo "没有答案文件，先 --inject"; exit 1; }
    cat "$ANS"
    ;;

--restore)
    if [ -s "$ANS" ]; then
        while read -r _ _ _ f; do
            [ -n "${f:-}" ] && do_restore "$f"
        done < "$ANS"
        rm -f "$ANS"
        echo "已按答案全部恢复"
    else
        echo "没有注入记录，按题库全量兜底恢复"
        for f in "${FAULTS[@]}"; do do_restore "$f"; done
    fi
    echo "复核："
    printf '  :80 %s   :22 %s   HTTP %s   syslog %sMB\n' \
        "$(has_listen 80 && echo LISTEN || echo -)" \
        "$(has_listen 22 && echo LISTEN || echo -)" \
        "$(http_code)" "$(syslog_mb)"
    ;;

*)
    echo "用法: chaos.sh --list | --inject N | --status | --answer | --restore"
    exit 1
    ;;
esac
