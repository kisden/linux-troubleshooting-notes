#!/usr/bin/env bash
# time-sync-restore.sh —— 时间同步恢复的标准流程
#
# 解决的问题：手工改过时钟（或 set-ntp false 之后忘了恢复）导致
# synchronized: no、证书校验失败、日志时间错乱。恢复不是「跑一条命令」，
# 而是一条有序的链：交回 NTP 管理 → 服务真的起来 → 跳变校正 → 三处验证。
#
# 用法：
#   sudo ./time-sync-restore.sh                 # 自动检测并恢复
#   sudo ./time-sync-restore.sh --force-set "2026-11-21 19:00:00"
#                                               # NTP 不可达时，先手工拉到接近真实值
#   sudo ./time-sync-restore.sh --dry-run       # 只报告将要做什么，不改动
#
# 退出码：0 已同步 / 1 命令执行成功但尚未同步（NTP 不通）/ 2 环境不满足

set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
hit()  { printf '%s[HIT]%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s[!]%s   %s\n' "$YEL" "$RST" "$*"; }
ok()   { printf '%s[OK]%s  %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s%s%s\n' "$DIM" "$*" "$RST"; }
step() { printf '\n%s== %s ==%s\n' "$GRN" "$*" "$RST"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

DRY=0
FORCE_SET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --force-set) FORCE_SET="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) warn "未知参数：$1"; exit 2 ;;
  esac
done

[ "$(id -u)" -ne 0 ] && { warn "需要 root 权限，请用 sudo 运行"; exit 2; }
[ "$DRY" = "1" ] && warn "dry-run 模式：只报告，不改动系统"

run() {
  if [ "$DRY" = "1" ]; then
    printf '  %s[dry]%s %s\n' "$DIM" "$RST" "$*"
  else
    printf '  %s$%s %s\n' "$DIM" "$RST" "$*"
    "$@"
  fi
}

hr
echo "时间同步恢复"
hr
echo "  恢复前时刻 : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  同步状态   : $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
echo "  NTP 开关   : $(timedatectl show -p NTP --value 2>/dev/null || echo unknown)"

# 识别同步服务（chrony 优先，其次 systemd-timesyncd）
SVC=""
for s in chrony systemd-timesyncd ntp; do
  if [ "$(systemctl show -p LoadState --value "$s.service" 2>/dev/null)" = "loaded" ]; then
    SVC="$s"; break
  fi
done
echo "  同步服务   : ${SVC:-未找到}"
echo "  服务状态   : $(systemctl is-active "${SVC:-none}.service" 2>/dev/null || echo unknown)"

# 记录恢复前偏差（若读得到）
BEFORE_OFFSET=""
if command -v chronyc >/dev/null 2>&1; then
  BEFORE_OFFSET=$(chronyc tracking 2>/dev/null | awk '/^System time/{print $4}' || true)
  [ -n "$BEFORE_OFFSET" ] && echo "  恢复前偏差 : ${BEFORE_OFFSET} 秒" || echo "  恢复前偏差 : 读不到（chronyd 可能未运行）"
fi

# ------------------------------------------------------------------
step "① 可选：先手工把时间拉到接近真实值"
# ------------------------------------------------------------------
if [ -n "$FORCE_SET" ]; then
  info "用于 NTP 完全不可达的环境（如虚拟 NAT 对 UDP/123 支持有限）"
  info "必须先关 NTP 再改，否则改完几秒内会被拉回"
  run timedatectl set-ntp false
  run date -s "$FORCE_SET"
  run date
else
  info "跳过（如需使用：--force-set \"YYYY-MM-DD HH:MM:SS\"）"
  info "注意：偏差到「天」这个量级时，靠 slew 慢调要跑很久，必须靠后面的 makestep"
fi

# ------------------------------------------------------------------
step "② 交回 NTP 管理（这一步会重新 enable + start 服务）"
# ------------------------------------------------------------------
run timedatectl set-ntp true

# ------------------------------------------------------------------
step "③ 确认服务真的起来了"
# ------------------------------------------------------------------
if [ -n "$SVC" ]; then
  run systemctl restart "$SVC"
  sleep 1
  if [ "$DRY" = "0" ]; then
    STATE=$(systemctl is-active "$SVC" 2>/dev/null || true)
    if [ "$STATE" = "active" ]; then
      ok "$SVC.service 已 active"
    else
      hit "$SVC.service 状态为 $STATE —— 后续 makestep 会失败"
      info "查原因：systemctl status $SVC --no-pager -l"
    fi
  fi
else
  warn "未找到同步服务，跳过重启"
fi

# ------------------------------------------------------------------
step "④ 等一轮更新，再强制跳变"
# ------------------------------------------------------------------
info "校正是持续过程，makestep 是一次性跳变；大偏差必须先跳变，slew 要跑很久"
info "等待 10 秒让 chronyd 完成首次源选择..."
[ "$DRY" = "0" ] && sleep 10

if [ "$SVC" = "chrony" ] && command -v chronyc >/dev/null 2>&1; then
  run chronyc makestep
else
  info "非 chrony 环境：systemd-timesyncd 会在启动时自行跳变，无需 makestep"
fi

# ------------------------------------------------------------------
step "⑤ 三处验证"
# ------------------------------------------------------------------
RC=0
if [ "$DRY" = "1" ]; then
  info "dry-run 结束，未做任何改动"
  exit 0
fi

echo
echo "  [a] chronyc tracking"
if command -v chronyc >/dev/null 2>&1; then
  TRACK=$(chronyc tracking 2>&1)
  if printf '%s' "$TRACK" | grep -q '506'; then
    hit "    506 Cannot talk to daemon —— 服务仍未运行"
    RC=1
  else
    OFFSET=$(printf '%s\n' "$TRACK" | awk '/^System time/{print $4}')
    STRATUM=$(printf '%s\n' "$TRACK" | awk '/^Stratum/{print $3}')
    SYNCED=$(printf '%s\n' "$TRACK" | awk '/^Leap status/{print $4, $5}')
    echo "    System time : ${OFFSET:-?} 秒"
    echo "    Stratum     : ${STRATUM:-?}"
    echo "    Leap status : ${SYNCED:-?}"
    if [ -n "${OFFSET:-}" ]; then
      ABSO=$(awk -v o="$OFFSET" 'BEGIN{printf "%.6f", (o<0?-o:o)}')
      SMALL=$(awk -v o="$ABSO" 'BEGIN{print (o<=0.1)?1:0}')
      [ "$SMALL" = "1" ] && ok "    偏差 ${ABSO} 秒 ≤ 100 ms" || { warn "    偏差 ${ABSO} 秒仍偏大"; RC=1; }
    fi
  fi
else
  info "    chronyc 不可用，跳过"
fi

echo
echo "  [b] timedatectl 同步标志"
SYNC_NOW=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)
echo "    NTPSynchronized: $SYNC_NOW"
if [ "$SYNC_NOW" = "yes" ]; then
  ok "    系统已回到同步状态"
else
  warn "    尚未同步 —— 等待一轮或检查上游可达性"
  RC=1
fi

echo
echo "  [c] 日志文件 mtime 是否跟随系统时钟"
SYSLOG=/var/log/syslog
[ -f "$SYSLOG" ] || SYSLOG=/var/log/messages
if [ -f "$SYSLOG" ]; then
  echo "    $SYSLOG"
  ls -l --time-style=full-iso "$SYSLOG" | sed 's/^/    /'
  MTIME=$(date -r "$SYSLOG" +%s 2>/dev/null || echo 0)
  NOW=$(date +%s)
  DELTA=$(( NOW - MTIME ))
  echo "    mtime 距现在: ${DELTA} 秒"
  if [ "$DELTA" -ge 0 ] && [ "$DELTA" -lt 600 ]; then
    ok "    日志文件正在按当前时间增长"
  elif [ "$DELTA" -lt 0 ]; then
    hit "    mtime 在未来 —— 写日志的进程还没重读时钟"
    info "    处理：sudo systemctl restart rsyslog"
    RC=1
  else
    warn "    mtime 落后 ${DELTA} 秒，若日志无新内容是正常的（无写入则 mtime 不变）"
    info "    判据是「有新日志时 mtime 是否跟得上」，不是绝对差值"
  fi
else
  info "    未找到 syslog/messages，跳过"
fi

# ------------------------------------------------------------------
hr
echo "结论"
hr
if [ "$RC" = "0" ]; then
  ok "时间同步已恢复"
  info "建议再验一次业务面：curl -v --cacert <crt> https://... 应不再报 not yet valid"
else
  warn "命令已执行，但同步尚未完成"
  info "虚拟 NAT 环境下 NTP 的 UDP/123 常被限制，此时不必纠结能否同步成功，"
  info "重点是理解「校正是持续过程、makestep 是一次性跳变」，并确认 synchronized 会变回 yes"
  info "排查上游：chronyc sources -v  → 是否只有 1 个源 / 全部 ^? 不可达"
fi
exit "$RC"
