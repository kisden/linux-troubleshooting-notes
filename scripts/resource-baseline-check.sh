#!/usr/bin/env bash
# resource-baseline-check.sh —— 内存与时间双维度巡检
#
# 这两个维度的共同点是「静默失效」：内存慢慢漏、时钟慢慢漂，都不报错，
# 等发现时已经是故障。本脚本把两类指标一次采齐，按阈值分级告警，
# 退出码可直接接监控（0 正常 / 1 警告 / 2 严重）。
#
# 用法：
#   ./resource-baseline-check.sh                 # 巡检并输出结论
#   ./resource-baseline-check.sh --save /var/lib/baseline/mt.json
#                                                 # 保存当前值作为基线
#   ./resource-baseline-check.sh --diff /var/lib/baseline/mt.json
#                                                 # 与基线比对，报告漂移量
#   --mem-warn 15 --off-warn 0.2                  # 自定义阈值（百分比 / 秒）
#
# 退出码：0 全部正常 / 1 存在警告项 / 2 存在严重项（需立即处理）

set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
bad()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YEL" "$RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s%s%s\n' "$DIM" "$*" "$RST"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

MEM_WARN=15          # available 占总量低于此百分比 → 警告
OFF_WARN=0.2         # 时间偏差超过此秒数 → 警告
OFF_BAD=1.0          # 超过此秒数 → 严重
SAVE=""; DIFF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --save)     SAVE="${2:-}"; shift 2 ;;
    --diff)     DIFF="${2:-}"; shift 2 ;;
    --mem-warn) MEM_WARN="${2:-15}"; shift 2 ;;
    --off-warn) OFF_WARN="${2:-0.2}"; shift 2 ;;
    -h|--help)  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) warn "未知参数：$1"; exit 1 ;;
  esac
done

RC=0
bump() { [ "$1" -gt "$RC" ] && RC="$1"; }

HOST=$(hostname)
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ------------------------------------------------------------------
# 内存
# ------------------------------------------------------------------
hr
echo "内存巡检 @ $HOST  $NOW"
hr

read -r TOT USED FREE SHARED BUFCACHE AVAIL < <(free -m | awk '/^Mem:/{print $2,$3,$4,$5,$6,$7}')
SWAP_T=$(free -m | awk '/^Swap:/{print $2}')
SWAP_U=$(free -m | awk '/^Swap:/{print $3}')

AVAIL_PCT=$(( AVAIL * 100 / TOT ))
USED_PCT=$(( USED * 100 / TOT ))

printf '  total %s MB / used %s MB (%s%%) / free %s MB / buff-cache %s MB / available %s MB (%s%%)\n' \
  "$TOT" "$USED" "$USED_PCT" "$FREE" "$BUFCACHE" "$AVAIL" "$AVAIL_PCT"
printf '  swap  %s MB / used %s MB\n' "$SWAP_T" "$SWAP_U"

# free 与 available 的差值，就是「可回收缓存」的规模
GAP=$(( AVAIL - FREE ))
echo "  free 与 available 差 ${GAP} MB —— 这部分是可回收缓存，判断水位只看 available"
echo

if [ "$AVAIL_PCT" -lt 5 ]; then
  bad "available 仅 ${AVAIL_PCT}% (${AVAIL} MB) —— 已在 OOM 边缘"; bump 2
elif [ "$AVAIL_PCT" -lt "$MEM_WARN" ]; then
  warn "available ${AVAIL_PCT}% (${AVAIL} MB) < 阈值 ${MEM_WARN}%"; bump 1
else
  ok "available ${AVAIL_PCT}% (${AVAIL} MB)"
fi

# si/so：一旦开始换页，离 OOM 就不远
if command -v vmstat >/dev/null 2>&1; then
  SI_SO=$(vmstat 1 2 | tail -1 | awk '{print $7, $8}')
  SI=$(echo "$SI_SO" | awk '{print $1}')
  SO=$(echo "$SI_SO" | awk '{print $2}')
  echo "  vmstat si/so: ${SI} / ${SO}  ${DIM}(1 秒采样)${RST}"
  if [ "${SI:-0}" -gt 0 ] || [ "${SO:-0}" -gt 0 ]; then
    warn "存在换页活动（si=${SI} so=${SO}）—— 内存压力已开始显性化"; bump 1
  else
    ok "无换页活动"
  fi
fi

# TOP3
echo
echo "  内存 TOP3："
ps aux --sort=-%mem 2>/dev/null | awk 'NR>1 && NR<=4 {printf "    %-10s %5s%% RSS %8s kB  %s\n", $1, $4, $6, $11}' || true

# OOM 计数
OOM_CNT=0
if [ "$(id -u)" = "0" ]; then
  OOM_CNT=$(dmesg -T 2>/dev/null | grep -c 'Killed process' || true)
  OC_CNT=$(dmesg -T 2>/dev/null | grep -c 'Memory cgroup out of memory' || true)
  GO_CNT=$(dmesg -T 2>/dev/null | grep -cE '^\[[^]]*\] Out of memory' || true)
  echo
  echo "  OOM 事件（本次开机以来）: 合计 ${OOM_CNT}（cgroup ${OC_CNT} / 全局 ${GO_CNT}）"
  if [ "${GO_CNT:-0}" -gt 0 ]; then
    bad "存在全局 OOM 记录 —— 整机内存曾被耗尽，被杀范围含任意进程"; bump 2
  elif [ "${OC_CNT:-0}" -gt 0 ]; then
    warn "存在 cgroup OOM 记录 —— 有服务撞到 MemoryMax，查 anon-rss 与上限"; bump 1
  else
    ok "无 OOM 事件"
  fi
else
  info "  非 root，跳过 OOM 历史统计（sudo 后可查）"
fi

# 未设限额的服务（只报数量，避免刷屏）
if [ "$(id -u)" = "0" ] && command -v systemctl >/dev/null 2>&1; then
  NO_LIMIT=0
  for u in $(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
    M=$(systemctl show -p MemoryMax --value "$u" 2>/dev/null || echo infinity)
    [ "$M" = "infinity" ] && NO_LIMIT=$(( NO_LIMIT + 1 ))
  done
  echo
  echo "  运行中服务未设 MemoryMax: ${NO_LIMIT} 个"
  if [ "$NO_LIMIT" -gt 30 ]; then
    info "  数量多属常见；重点给「已知会涨内存」的服务设限（Java/Node/缓存类）"
  fi
fi

# ------------------------------------------------------------------
# 时间
# ------------------------------------------------------------------
hr
echo "时间巡检"
hr

LOCAL_T=$(timedatectl show -p LocalTime --value 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
RTC_T=$(timedatectl show -p RTCTime --value 2>/dev/null || echo "")
SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)
NTP_ON=$(timedatectl show -p NTP --value 2>/dev/null || echo unknown)
TZNAME=$(timedatectl show -p Timezone --value 2>/dev/null || echo "?")

echo "  Local time  : ${LOCAL_T}"
[ -n "$RTC_T" ] && echo "  RTC time    : ${RTC_T}"
echo "  Timezone    : ${TZNAME}"
echo "  NTP 开关    : ${NTP_ON}"
echo "  synchronized: ${SYNC}"
echo

if [ "$SYNC" = "yes" ]; then
  ok "系统处于同步状态"
else
  bad "synchronized = ${SYNC} —— 系统未同步，所有依赖时钟的判断都不可靠"; bump 2
  info "  恢复：sudo timedatectl set-ntp true && sudo systemctl restart chrony"
fi

# 同步服务
SVC=""
for s in chrony systemd-timesyncd ntp; do
  if [ "$(systemctl show -p LoadState --value "$s.service" 2>/dev/null)" = "loaded" ]; then SVC="$s"; break; fi
done
if [ -n "$SVC" ]; then
  ST=$(systemctl is-active "$SVC" 2>/dev/null || true)
  echo "  同步服务    : ${SVC}.service → ${ST}"
  [ "$ST" != "active" ] && { bad "${SVC} 未运行 —— 这是 506 Cannot talk to daemon 的根因"; bump 2; }
fi

# 偏差
OFFSET=""
if command -v chronyc >/dev/null 2>&1; then
  TRACK=$(chronyc tracking 2>&1)
  if printf '%s' "$TRACK" | grep -q '506'; then
    bad "chronyc tracking → 506 Cannot talk to daemon（chronyd 未运行，不是 chrony 坏了）"; bump 2
  else
    OFFSET=$(printf '%s\n' "$TRACK" | awk '/^System time/{print $4}')
    STRATUM=$(printf '%s\n' "$TRACK" | awk '/^Stratum/{print $3}')
    echo "  System time : ${OFFSET:-?} 秒"
    echo "  Stratum     : ${STRATUM:-?}"
    if [ -n "${OFFSET:-}" ]; then
      ABSO=$(awk -v o="$OFFSET" 'BEGIN{printf "%.6f", (o<0?-o:o)}')
      if awk -v o="$ABSO" -v t="$OFF_BAD" 'BEGIN{exit !(o>t)}'; then
        bad "时间偏差 ${ABSO} 秒 > ${OFF_BAD} 秒 —— 证书/认证/分布式锁都会出错"; bump 2
      elif awk -v o="$ABSO" -v t="$OFF_WARN" 'BEGIN{exit !(o>t)}'; then
        warn "时间偏差 ${ABSO} 秒 > ${OFF_WARN} 秒"; bump 1
      else
        ok "时间偏差 ${ABSO} 秒"
      fi
    fi
    [ "${STRATUM:-9}" = "0" ] && { bad "Stratum 0 —— 本地时钟不可信，等同未同步"; bump 2; }

    # 时间源数量
    SRC_CNT=$(chronyc sources -v 2>/dev/null | grep -c '^\^\*' || true)
    echo "  可达时间源  : ${SRC_CNT:-0}"
    if [ "${SRC_CNT:-0}" -eq 0 ]; then
      bad "无可用时间源 —— 已失去自动校正能力"; bump 2
    elif [ "${SRC_CNT:-0}" -eq 1 ]; then
      warn "仅 1 个时间源，源一挂就是静默失步，建议至少两个"; bump 1
    else
      ok "时间源 ${SRC_CNT} 个"
    fi
  fi
else
  info "  未安装 chronyc，无法读取偏差量"
fi

# ------------------------------------------------------------------
# 基线保存 / 比对
# ------------------------------------------------------------------
if [ -n "$SAVE" ]; then
  mkdir -p "$(dirname "$SAVE")" 2>/dev/null || true
  cat > "$SAVE" <<EOF
{
  "saved_at": "${NOW}",
  "host": "${HOST}",
  "mem_total_mb": ${TOT},
  "mem_available_mb": ${AVAIL},
  "mem_available_pct": ${AVAIL_PCT},
  "swap_used_mb": ${SWAP_U},
  "oom_count": ${OOM_CNT:-0},
  "time_offset_s": "${OFFSET:-}",
  "ntp_synchronized": "${SYNC}"
}
EOF
  hr
  ok "基线已保存：$SAVE"
  cat "$SAVE" | sed 's/^/  /'
fi

if [ -n "$DIFF" ] && [ -f "$DIFF" ]; then
  hr
  echo "与基线比对（$DIFF）"
  hr
  OLD_AVAIL=$(grep -oP '"mem_available_mb":\s*\K[0-9]+' "$DIFF" 2>/dev/null || echo "")
  OLD_PCT=$(grep -oP '"mem_available_pct":\s*\K[0-9]+' "$DIFF" 2>/dev/null || echo "")
  OLD_OOM=$(grep -oP '"oom_count":\s*\K[0-9]+' "$DIFF" 2>/dev/null || echo "")
  OLD_AT=$(grep -oP '"saved_at":\s*"\K[^"]+' "$DIFF" 2>/dev/null || echo "?")

  echo "  基线时刻 : $OLD_AT"
  if [ -n "$OLD_AVAIL" ]; then
    echo "  available: ${OLD_AVAIL} MB → ${AVAIL} MB  (差 $(( AVAIL - OLD_AVAIL )) MB)"
  fi
  if [ -n "$OLD_OOM" ]; then
    DELTA=$(( ${OOM_CNT:-0} - OLD_OOM ))
    if [ "$DELTA" -gt 0 ]; then
      bad "OOM 事件增加 ${DELTA} 起（${OLD_OOM} → ${OOM_CNT}）"; bump 2
    else
      ok "OOM 事件未增加"
    fi
  fi
  info "  注：available 的短期波动属正常（缓存回收），只有单调下降才有意义"
fi

# ------------------------------------------------------------------
hr
echo "结论"
hr
case "$RC" in
  0) ok "全部指标正常" ;;
  1) warn "存在警告项，建议 24 小时内处理" ;;
  2) bad "存在严重项，需立即处理" ;;
esac
info "内存：服务「凭空消失」时先看退出码（137=SIGKILL），再 dmesg | grep 'Killed process'"
info "时间：偏差 >1 秒时证书会报 not yet valid / has expired，而报错文本里不会提时间"
exit "$RC"
