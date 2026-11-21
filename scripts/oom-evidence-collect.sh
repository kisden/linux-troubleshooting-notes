#!/usr/bin/env bash
# oom-evidence-collect.sh —— OOM 证据链一键采集
#
# 适用场景：某个服务/进程「凭空消失」，应用日志里查不到任何报错。
# 本脚本按「退出码 → 内核日志 → 整机水位 → 限额比」的顺序取证，
# 每一步都在缩小「是谁动的手」的范围。
#
# 用法：
#   sudo ./oom-evidence-collect.sh              # 只看本次开机以来的 OOM 记录
#   sudo ./oom-evidence-collect.sh 998           # 附带查询指定 PID 的 oom_score
#   sudo ./oom-evidence-collect.sh --since 1h    # 只看最近 1 小时（dmesg -T 无法过滤，用 journal）
#
# 退出码：0 未发现 OOM / 1 发现 OOM 事件 / 2 环境不满足（非 root 等）

set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
hit()  { printf '%s[HIT]%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s[!]%s   %s\n' "$YEL" "$RST" "$*"; }
ok()   { printf '%s[OK]%s  %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s%s%s\n' "$DIM" "$*" "$RST"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

PID_ARG=""
SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PID_ARG="$1"; shift ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  warn "dmesg 需要 root 权限，请用 sudo 运行"
  exit 2
fi

# ------------------------------------------------------------------
# ① 内核日志：OOM 的唯一现场
# ------------------------------------------------------------------
hr
echo "① 内核 OOM 记录"
hr

# dmesg -T 输出人类可读时间；环形缓冲可能已被刷掉，所以同时备一条 journal 通道
OOM_LINES=$(dmesg -T 2>/dev/null | grep -iE 'out of memory|killed process' || true)

if [ -n "$SINCE" ]; then
  info "使用 journal 通道（--since $SINCE），内核日志在 journal 里有一份副本"
  OOM_LINES=$(journalctl -b -k --since "-$SINCE" 2>/dev/null | grep -iE 'out of memory|killed process' || true)
fi

if [ -z "$OOM_LINES" ]; then
  ok "未发现 OOM 记录"
  echo
  info "如果确实有进程消失，往下排查："
  info "  · 退出码 143 → 被 SIGTERM，查 systemctl stop / 关机 / 部署脚本"
  info "  · 退出码 1   → 应用自身退出，此时应用日志应该有记录"
  info "  · 无任何痕迹 → 人为 kill -9，查 audit / 编排系统 / history"
  exit 0
fi

TOTAL=$(printf '%s\n' "$OOM_LINES" | grep -c 'Killed process' || true)
CG=$(printf '%s\n' "$OOM_LINES" | grep -c 'Memory cgroup out of memory' || true)
GL=$(printf '%s\n' "$OOM_LINES" | grep -cE '^\[[^]]*\] Out of memory' || true)

hit "共 $TOTAL 条 Killed process 记录（cgroup: $CG / 全局: $GL）"
echo
info "最近 5 条："
printf '%s\n' "$OOM_LINES" | grep 'Killed process' | tail -5 | sed 's/^/  /'
echo

# ------------------------------------------------------------------
# ② 判定触发域：cgroup 限额 or 整机耗尽
# ------------------------------------------------------------------
hr
echo "② 触发域判定"
hr

if [ "$CG" -gt 0 ] && [ "$GL" -eq 0 ]; then
  ok "全部为 cgroup OOM —— 触发域是 MemoryMax，整机内存健康"
  info "  判据：首行为 'Memory cgroup out of memory: Killed process ...'"
  info "  影响面：只杀该 cgroup 内的进程，其他服务无感"
elif [ "$GL" -gt 0 ] && [ "$CG" -eq 0 ]; then
  hit "存在全局 OOM —— 整机物理内存 + swap 已耗尽"
  info "  判据：首行为 'Out of memory: Killed process ...'（无 Memory cgroup 前缀）"
  info "  风险：被杀范围是全系统，可能含 sshd / journald / 数据库"
  info "  动作：先确认系统可用，再查谁吃光了内存"
else
  warn "两种记录并存 —— 可能先 cgroup 后升级为全局，按全局 OOM 处理"
fi

# ------------------------------------------------------------------
# ③ 限额是否真的生效：cgroup v2 没有独立限额行，看 anon-rss 贴不贴顶
# ------------------------------------------------------------------
hr
echo "③ 限额生效判定（cgroup v2 无独立限额行，看 anon-rss）"
hr

LAST=$(printf '%s\n' "$OOM_LINES" | grep 'Killed process' | tail -1)
ANON=$(printf '%s' "$LAST" | grep -oP 'anon-rss:\K[0-9]+' || true)
TVM=$(printf '%s'  "$LAST" | grep -oP 'total-vm:\K[0-9]+' || true)

if [ -n "$ANON" ]; then
  ANON_MIB=$(( ANON / 1024 ))
  echo "  被杀进程 anon-rss : ${ANON} kB  ≈ ${ANON_MIB} MiB"
  if [ -n "$TVM" ]; then
    TVM_MIB=$(( TVM / 1024 ))
    echo "  total-vm（VSZ）   : ${TVM} kB  ≈ ${TVM_MIB} MiB  ${DIM}← 虚拟地址空间，不计入 cgroup，不要用来看占用${RST}"
    if [ "$ANON" -gt 0 ] && [ "$TVM" -gt $(( ANON * 5 )) ]; then
      info "  VSZ 是 RSS 的 $(( TVM / ANON )) 倍，属正常（解释器/运行时预留地址空间）"
    fi
  fi
  echo
  info "  判据：anon-rss 贴着 MemoryMax 的上限（通常 > 90%），才能证明是限额触发"
  info "  查该单元的当前限额：systemctl show <unit> -p MemoryMax -p MemoryHigh"
else
  warn "未能从日志解析出 anon-rss（日志格式可能不同），请手工核对那一行"
fi

# ------------------------------------------------------------------
# ④ 整机水位：cgroup OOM 下应当几乎无变化
# ------------------------------------------------------------------
hr
echo "④ 整机内存水位"
hr
free -h | sed 's/^/  /'
echo
AVAIL=$(free -m | awk '/^Mem:/{print $7}')
TOTALM=$(free -m | awk '/^Mem:/{print $2}')
[ -n "$AVAIL" ] && [ -n "$TOTALM" ] && [ "$TOTALM" -gt 0 ] && \
  echo "  available 占比: $(( AVAIL * 100 / TOTALM ))%"
echo
if [ "$CG" -gt 0 ] && [ "$AVAIL" -gt $(( TOTALM / 3 )) ]; then
  ok "available 仍充足 —— 与 cgroup OOM 的预期一致（内存死在笼子里，已归还）"
  info "  注意：cgroup OOM 时 used 甚至可能比注入前更低，被杀进程的页会立刻回收"
else
  warn "available 偏低，注意是否已进入全局 OOM 区间"
fi

# ------------------------------------------------------------------
# ⑤ 可选：指定 PID 的 oom_score（进程还活着时才有意义）
# ------------------------------------------------------------------
if [ -n "$PID_ARG" ]; then
  hr
  echo "⑤ 进程 $PID_ARG 的 OOM 相关指标"
  hr
  if [ -d "/proc/$PID_ARG" ]; then
    echo "  comm          : $(cat /proc/$PID_ARG/comm 2>/dev/null)"
    echo "  oom_score     : $(cat /proc/$PID_ARG/oom_score 2>/dev/null)      ← 越高越先被杀"
    echo "  oom_score_adj : $(cat /proc/$PID_ARG/oom_score_adj 2>/dev/null)  ← -900 为受保护，0 为默认"
    echo "  VmRSS         : $(awk '/VmRSS/{print $2, $3}' /proc/$PID_ARG/status 2>/dev/null)"
    echo "  VmSize        : $(awk '/VmSize/{print $2, $3}' /proc/$PID_ARG/status 2>/dev/null)  ${DIM}← 不要用这个判断占用${RST}"
    echo
    info "  给关键进程加保护：systemctl edit <svc> → [Service] OOMScoreAdjust=-900"
  else
    warn "PID $PID_ARG 不存在（已被杀或从未存在）"
  fi
fi

hr
echo "结论"
hr
info "服务「凭空消失」的排查顺序：echo \$? → dmesg | grep 'Killed process' → free -h → anon-rss"
info "137 = 128+9  = SIGKILL（OOM 或 kill -9）→ 应用日志必然为空"
info "143 = 128+15 = SIGTERM（systemctl stop / 关机）→ 应该有退出日志"
exit 1
