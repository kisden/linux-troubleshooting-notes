#!/usr/bin/env bash
# time-drift-triage.sh —— 时间漂移分层诊断
#
# 适用场景：证书突然「尚未生效/已过期」、日志时间乱序、Kerberos/JWT 登录失败、
# cron 任务不执行——这些报错里都不会提「时间」，但根因可能在时钟上。
#
# 本脚本按「RTC → 系统时钟 → 同步服务 → 时间源 → 偏差量」五层往下走，
# 每层给出判据，最后输出结论与建议动作。
#
# 用法：
#   ./time-drift-triage.sh          # 只读诊断，不需要 root
#   ./time-drift-triage.sh -v       # 额外打印 chrony 原始输出
#
# 退出码：0 正常 / 1 有偏差但已同步 / 2 未同步或服务未运行 / 3 严重漂移

set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
hit()  { printf '%s[HIT]%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s[!]%s   %s\n' "$YEL" "$RST" "$*"; }
ok()   { printf '%s[OK]%s  %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s%s%s\n' "$DIM" "$*" "$RST"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

RC=0

# ------------------------------------------------------------------
# ① 三层时钟总览
# ------------------------------------------------------------------
hr
echo "① 三层时钟"
hr
timedatectl 2>/dev/null | sed 's/^/  /' || { warn "timedatectl 不可用（非 systemd 系统？）"; exit 3; }
echo

LOCAL_T=$(timedatectl show -p LocalTime --value 2>/dev/null || true)
RTC_T=$(timedatectl show -p RTCTime   --value 2>/dev/null || true)
SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")
NTP_ON=$(timedatectl show -p NTP --value 2>/dev/null || echo "unknown")

if [ -n "$RTC_T" ] && [ -n "$LOCAL_T" ]; then
  # RTC 与系统时钟的差（秒）。正常应接近 0，差几小时通常是时区/UTC 标志问题
  RTC_EPOCH=$(date -d "${RTC_T%%.*}" +%s 2>/dev/null || echo 0)
  LOCAL_EPOCH=$(date -d "${LOCAL_T%%.*}" +%s 2>/dev/null || echo 0)
  if [ "$RTC_EPOCH" -gt 0 ] && [ "$LOCAL_EPOCH" -gt 0 ]; then
    DIFF=$(( LOCAL_EPOCH - RTC_EPOCH ))
    ABS=${DIFF#-}
    echo "  RTC 与系统时钟差: ${DIFF} 秒"
    if [ "$ABS" -gt 3600 ]; then
      warn "差值超过 1 小时 —— 常见于「RTC 存 UTC 但系统按本地时间解读」，不是真的漂移"
      info "  核对：timedatectl 的 'RTC in local TZ' 应为 no"
    elif [ "$ABS" -gt 60 ]; then
      warn "差值 ${ABS} 秒 —— RTC 电池或开机时未同步"
    else
      ok "RTC 与系统时钟基本一致"
    fi
  fi
fi
echo

# ------------------------------------------------------------------
# ② 同步服务是否活着（506 的根因往往在这里）
# ------------------------------------------------------------------
hr
echo "② 同步服务状态"
hr

SVC=""
for s in chrony systemd-timesyncd ntp; do
  if systemctl list-unit-files "$s.service" >/dev/null 2>&1 && \
     [ "$(systemctl show -p LoadState --value "$s.service" 2>/dev/null)" = "loaded" ]; then
    SVC="$s"; break
  fi
done

if [ -z "$SVC" ]; then
  hit "未找到任何 NTP 同步服务（chrony / systemd-timesyncd / ntp 都没有）"
  RC=2
else
  STATE=$(systemctl is-active "$SVC" 2>/dev/null || true)
  ENABLED=$(systemctl is-enabled "$SVC" 2>/dev/null || true)
  echo "  服务      : $SVC.service"
  echo "  is-active : $STATE"
  echo "  is-enabled: $ENABLED"
  echo
  if [ "$STATE" = "active" ]; then
    ok "$SVC 正在运行"
  else
    hit "$SVC 未运行（$STATE）—— 这是 '506 Cannot talk to daemon' 的真正原因"
    info "  'timedatectl set-ntp false' 会把正在跑的 NTP 客户端一起停掉，不只是关开关"
    info "  恢复：sudo timedatectl set-ntp true && sudo systemctl restart $SVC"
    RC=2
  fi
  if [ "$NTP_ON" = "no" ] && [ "$STATE" = "active" ]; then
    warn "NTP 开关为 no 但服务在跑 —— 系统不会自动校正，服务只是空转"
    RC=2
  fi
fi
echo

# ------------------------------------------------------------------
# ③ 偏差量（客户端能否读到，本身也是证据）
# ------------------------------------------------------------------
hr
echo "③ 时间偏差"
hr

if command -v chronyc >/dev/null 2>&1; then
  TRACK=$(chronyc tracking 2>&1)
  if printf '%s' "$TRACK" | grep -q '506'; then
    hit "chronyc tracking → 506 Cannot talk to daemon"
    info "  不是 chrony 坏了，是 chronyd 没在跑。读不到偏差 ≠ 没有漂移"
    RC=2
  else
    OFFSET=$(printf '%s\n' "$TRACK" | awk '/^System time/{print $4}')
    STRATUM=$(printf '%s\n' "$TRACK" | awk '/^Stratum/{print $3}')
    LASTOFF=$(printf '%s\n' "$TRACK" | awk '/^Last offset/{print $4}')
    LEAP=$(printf '%s\n' "$TRACK" | awk '/^Leap status/{$1="";$2="";print substr($0,3)}')
    [ "$VERBOSE" = "1" ] && { echo; printf '%s\n' "$TRACK" | sed 's/^/  /'; echo; }

    echo "  System time : ${OFFSET:-?} 秒（当前偏差）"
    echo "  Last offset : ${LASTOFF:-?} 秒（上次校正量）"
    echo "  Stratum     : ${STRATUM:-?}（0 表示本地时钟不可信）"
    echo "  Leap status : ${LEAP:-?}"
    echo

    if [ -n "${OFFSET:-}" ]; then
      # 用 awk 做浮点比较，避免 bc 依赖
      ABSO=$(awk -v o="$OFFSET" 'BEGIN{printf "%.6f", (o<0?-o:o)}')
      BIG=$(awk -v o="$ABSO" 'BEGIN{print (o>1.0)?1:0}')
      MID=$(awk -v o="$ABSO" 'BEGIN{print (o>0.1)?1:0}')
      if [ "$BIG" = "1" ]; then
        hit "偏差 ${ABSO} 秒 > 1 秒 —— TLS/Kerberos/JWT/分布式锁都会开始出错"
        info "  证书会报 not yet valid / has expired，而错误文本不会提时间"
        RC=3
      elif [ "$MID" = "1" ]; then
        warn "偏差 ${ABSO} 秒 > 100 ms —— 建议关注，常见阈值就在这里"
        [ "$RC" -lt 1 ] && RC=1
      else
        ok "偏差 ${ABSO} 秒，处于健康区间（< 100 ms）"
      fi
    fi
    if [ "${STRATUM:-99}" = "0" ]; then
      hit "Stratum 0 —— 本地时钟不可信，等同未同步"
      RC=3
    elif [ -n "${STRATUM:-}" ] && [ "$STRATUM" -gt 10 ] 2>/dev/null; then
      warn "Stratum $STRATUM 偏高（>10），上游链路可能很长"
    fi
  fi
else
  warn "未安装 chronyc，改用 timedatectl 的同步标志判断"
fi
echo

# ------------------------------------------------------------------
# ④ 时间源数量：单源一挂就是静默失步
# ------------------------------------------------------------------
hr
echo "④ 时间源"
hr

if command -v chronyc >/dev/null 2>&1 && ! printf '%s' "${TRACK:-}" | grep -q '506'; then
  SRC=$(chronyc sources -v 2>/dev/null || true)
  [ "$VERBOSE" = "1" ] && { printf '%s\n' "$SRC" | sed 's/^/  /'; echo; }
  CNT=$(printf '%s\n' "$SRC" | grep -c '^\^\*' || true)
  TOTAL_SRC=$(printf '%s\n' "$SRC" | grep -cE '^\^[*+-?]' || true)
  echo "  可达源（^*）: ${CNT:-0} / 配置源 ${TOTAL_SRC:-0}"
  echo
  if [ "${CNT:-0}" -eq 0 ]; then
    hit "没有任何可达时间源 —— 已完全失去自动校正能力"
    RC=3
  elif [ "${CNT:-0}" -eq 1 ]; then
    warn "只有 1 个可达源 —— 该源一挂就是静默失步，建议至少配两个"
    [ "$RC" -lt 1 ] && RC=1
  else
    ok "有 ${CNT} 个可达源"
  fi
else
  info "跳过（chronyd 不可达，先修 ②）"
fi
echo

# ------------------------------------------------------------------
# ⑤ 结论
# ------------------------------------------------------------------
hr
echo "结论"
hr
case "$RC" in
  0) ok "时钟健康：已同步、偏差在 100 ms 内、有多个可用源" ;;
  1) warn "可用但需关注：偏差偏大或时间源偏少，尚未到故障阈值" ;;
  2) hit "同步链路不通：服务未运行 / NTP 开关为 no / chronyd 不可达"
     info "  下一步：sudo timedatectl set-ntp true && sudo systemctl restart ${SVC:-chrony}" ;;
  3) hit "存在严重时间漂移：偏差 > 1 秒或 Stratum 0 或无可用源"
     info "  影响面：TLS 证书校验、日志排序、Kerberos/JWT、数据库主从"
     info "  恢复：sudo timedatectl set-ntp true → restart → sleep 10 → sudo chronyc makestep" ;;
esac
echo
info "判读要点："
info "  · 偏差 > 1 秒 → 证书会报 not yet valid / has expired，而报错里不提时间"
info "  · 506 Cannot talk to daemon → 先 is-active，别去重装 chrony"
info "  · 时钟回跳后 journalctl -n 拿到的是「时间最大」而非「最新写入」，用 --since/--until"
exit "$RC"
