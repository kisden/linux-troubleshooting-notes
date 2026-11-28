#!/usr/bin/env bash
# blindbox-audit.sh —— 盲盒前的 6 维健康基线巡检
#
# 这个脚本是 chaos.sh 的"反面"：注入器的每一段自检，反过来就是一条健康判据。
# 开盲盒之前跑一遍，确认环境干净；盲盒结束后再跑一遍，确认恢复彻底。
# 判据全部来自分册二至五的实测结论，不是凭感觉设的阈值。
#
# 用法：
#   ./blindbox-audit.sh              正常输出（OK / WARN / FAIL）
#   ./blindbox-audit.sh --quiet      只打印 WARN 与 FAIL
#   sudo ./blindbox-audit.sh         多拿到 :22 的监听者身份与 syslog 体积
#
# 退出码：0 全部通过 / 1 有 WARN / 2 有 FAIL（可直接接监控）

set -u

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

FAILS=0
WARNS=0

ok()   { [ "$QUIET" -eq 1 ] || printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
warn() { WARNS=$((WARNS + 1)); printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '\033[31m[FAIL]\033[0m %s\n' "$*"; }
head_() { [ "$QUIET" -eq 1 ] || printf '\n\033[1m%s\033[0m\n' "$*"; }

has_listen() {
    ss -lntH 2>/dev/null | awk -v want=":$1" '$4 ~ (want "$") {found=1} END{exit !found}'
}

listen_owner() {
    ss -lntpH "sport = :$1" 2>/dev/null | head -1 | sed -n 's/.*users:((\([^,]*\).*/\1/p'
}

mb_of() {
    local v
    v=$(du -m "$1" 2>/dev/null | awk '{print $1}')
    printf '%s' "${v:-0}"
}

echo "盲盒环境巡检  $(date '+%F %T')  $(hostname)"

# ---------- 1. 容量：日志体积 ----------
head_ "1/6 容量（日志）"
if [ -r /var/log/syslog ]; then
    SZ=$(mb_of /var/log/syslog)
    if [ "$SZ" -ge 500 ]; then
        fail "syslog ${SZ}MB ≥ 500MB：log_flood 残留，或 rsyslog 正在被刷"
    elif [ "$SZ" -ge 200 ]; then
        warn "syslog ${SZ}MB ≥ 200MB：增长异常，看 du -sh /var/log/* 排前三"
    else
        ok "syslog ${SZ}MB"
    fi
else
    warn "读不到 /var/log/syslog（权限或路径不同），改用 journalctl --disk-usage"
fi

# ---------- 2. 端口：80 / 22 各自的监听者 ----------
head_ "2/6 端口"
if has_listen 80; then
    OWN=$(listen_owner 80)
    case "$OWN" in
    nginx*) ok ":80 由 $OWN 监听";;
    "")     warn ":80 在听，但取不到进程名（非 root 运行？）";;
    *)      fail ":80 被 $OWN 占用，不是 nginx —— port_busy 形态";;
    esac
else
    fail ":80 无人监听 —— nginx 没起来"
fi

if has_listen 22; then
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        ok ":22 在听（ssh.socket 激活，端口归 systemd 持有）"
    else
        ok ":22 在听（$(listen_owner 22)）"
    fi
else
    fail ":22 无人监听 —— ssh_down 形态，控制台之外的连接会全断"
fi

# ---------- 3. 站点：状态码 + Server 头 ----------
head_ "3/6 站点"
CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/ 2>/dev/null || echo 000)
SRV=$(curl -sI -m 5 http://127.0.0.1/ 2>/dev/null | sed -n 's/^[Ss]erver: *//p' | tr -d '\r' | head -1)
case "$CODE" in
200|301|302) ok "HTTP $CODE，Server: ${SRV:-未知}";;
403)         fail "HTTP 403 —— perm_denied 形态（先 sudo -u www-data test -r，再 namei -l）";;
404)         warn "HTTP 404 —— 站点在，但首页不存在（配置或文件缺失）";;
5??)         fail "HTTP $CODE —— 上游或配置错误";;
000)         fail "连不上 127.0.0.1:80（服务未起，或本机回环被拦）";;
*)           warn "HTTP $CODE";;
esac

# ---------- 4. 解析：getent + hosts 异常条目 ----------
head_ "4/6 解析"
DNS=$(getent hosts www.ubuntu.com 2>/dev/null | awk '{print $1}' | paste -sd, -)
if [ -z "$DNS" ]; then
    fail "getent 无输出 —— 解析链断（先看 resolvectl status，再看 /etc/hosts）"
elif printf '%s' "$DNS" | grep -qE '(^|,)(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; then
    fail "getent 返回本地/内网地址（$DNS）—— hosts 被改写或上游被指向内网"
else
    ok "getent 返回 $DNS"
fi

BADHOSTS=$(awk '!/^#/ && NF>=2 && $1 ~ /^(127\.|10\.|192\.168\.)/ {
        for (i=2; i<=NF; i++) if ($i ~ /\.(com|cn|net|org)$/) {print $1" "$i; break}
    }' /etc/hosts 2>/dev/null)
if [ -n "$BADHOSTS" ]; then
    warn "hosts 里有公网域名指向本地/内网：$(echo "$BADHOSTS" | paste -sd'; ' -)"
else
    ok "hosts 无公网域名劫持条目"
fi

# ---------- 5. 时间：同步状态 ----------
head_ "5/6 时间"
if command -v timedatectl >/dev/null; then
    SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    NTP=$(timedatectl show -p NTP --value 2>/dev/null)
    if [ "$SYNC" = "yes" ]; then
        ok "synchronized: yes（NTP=$NTP）"
    else
        fail "synchronized: ${SYNC:-unknown} —— 时间未同步，证书与日志排序都会受影响"
    fi
else
    warn "没有 timedatectl"
fi

# ---------- 6. 调度：定时任务 ----------
head_ "6/6 调度"
if command -v crontab >/dev/null; then
    N=$(crontab -l 2>/dev/null | grep -vcE '^[[:space:]]*(#|$)')
    if [ "$N" -eq 0 ]; then
        warn "当前用户没有定时任务（若基线本来有，说明被清过）"
    else
        ok "当前用户 $N 条定时任务"
        crontab -l 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | sed 's/^/       /'
    fi
else
    warn "没有 crontab 命令"
fi

echo
printf '结论：FAIL %d 项，WARN %d 项\n' "$FAILS" "$WARNS"
[ "$FAILS" -gt 0 ] && exit 2
[ "$WARNS" -gt 0 ] && exit 1
echo "环境干净，可以开盲盒"
exit 0
