#!/usr/bin/env bash
# mem-safe-run.sh —— 在 cgroup 限额下运行命令，并自动采集 OOM 证据
#
# 解决的问题：想复现 / 验证「内存耗尽被内核杀掉」，但不能让失控进程吃光整机
# （全局 OOM 会随机杀 sshd、journald，机器当场失联，证据也拿不全）。
# 本脚本把目标进程关进 MemoryMax 笼子，跑完自动对比内存前后值、抓 dmesg、
# 算 anon-rss 与限额的比值，一次性给出完整的证据链。
#
# 用法：
#   sudo ./mem-safe-run.sh 150M python3 /tmp/oom_eat.py
#   sudo ./mem-safe-run.sh 512M --swap 256M ./my_service
#   sudo ./mem-safe-run.sh 1G --unit mytest -- sleep 60
#
#   --unit NAME   自定义 scope 单元名（默认 memlab-<pid>）
#   --swap SIZE   同时限制 swap（MemorySwapMax），测试「禁用 swap 后更早 OOM」
#   --          参数分隔，之后全部作为命令
#
# 退出码：透传被运行命令的退出码（被 SIGKILL 时为 137），
#         环境不满足时返回 2。
#
# 注意：--scope 让命令在当前终端同步执行，因此 $? 拿到的就是命令自己的退出码。
#       若改成 --service 后台运行，$? 只会是 systemctl 的返回码，拿不到 137。

set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
hit()  { printf '%s[HIT]%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s[!]%s   %s\n' "$YEL" "$RST" "$*"; }
ok()   { printf '%s[OK]%s  %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s%s%s\n' "$DIM" "$*" "$RST"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

LIMIT=""
SWAP=""
UNIT=""
CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --unit)  UNIT="${2:-}"; shift 2 ;;
    --swap)  SWAP="${2:-}"; shift 2 ;;
    --)      shift; CMD=("$@"); break ;;
    -h|--help) usage ;;
    *)
      if [ -z "$LIMIT" ]; then LIMIT="$1"; shift
      else CMD=("$@"); break
      fi ;;
  esac
done

[ -z "$LIMIT" ] && usage
[ ${#CMD[@]} -eq 0 ] && usage
[ "$(id -u)" -ne 0 ] && { warn "systemd-run 设置 cgroup 需要 root，请用 sudo 运行"; exit 2; }
command -v systemd-run >/dev/null || { warn "未找到 systemd-run"; exit 2; }

UNIT=${UNIT:-memlab-$$}
MEM_BEFORE=$(free -m | awk '/^Mem:/{print $7}')   # available，单位 MB
USED_BEFORE=$(free -m | awk '/^Mem:/{print $3}')
T0=$(date '+%Y-%m-%d %H:%M:%S')

hr
echo "限额运行"
hr
echo "  单元      : $UNIT"
echo "  内存上限  : MemoryMax=$LIMIT${SWAP:+  MemorySwapMax=$SWAP}"
echo "  命令      : ${CMD[*]}"
echo "  起始时刻  : $T0"
echo "  available : ${MEM_BEFORE} MB（used ${USED_BEFORE} MB）"
hr

# 记录运行前的时间戳，用于后面从 dmesg 里只捞本次的记录
START_EPOCH=$(date +%s)

RUN_ARGS=(-p "MemoryMax=$LIMIT")
[ -n "$SWAP" ] && RUN_ARGS+=(-p "MemorySwapMax=$SWAP")

systemd-run --unit="$UNIT" --scope -q "${RUN_ARGS[@]}" "${CMD[@]}"
RC=$?

hr
echo "运行结束"
hr
printf '  退出码    : %s\n' "$RC"
case "$RC" in
  137) hit "137 = 128 + 9 = SIGKILL —— 被信号杀死，应用日志必然为空" ;;
  143) warn "143 = 128 + 15 = SIGTERM —— 有人发了 TERM（stop / 关机 / 部署）" ;;
  0)   ok "正常退出（0）" ;;
  *)   warn "非信号退出（$RC）—— 应用自身返回，此时应用日志应该有记录" ;;
esac
echo

# ------------------------------------------------------------------
# 内存前后对比
# ------------------------------------------------------------------
MEM_AFTER=$(free -m | awk '/^Mem:/{print $7}')
USED_AFTER=$(free -m | awk '/^Mem:/{print $3}')
echo "  内存前后  : available ${MEM_BEFORE} → ${MEM_AFTER} MB   (${DIM}差 $(( MEM_AFTER - MEM_BEFORE )) MB${RST})"
echo "              used      ${USED_BEFORE} → ${USED_AFTER} MB   (${DIM}差 $(( USED_AFTER - USED_BEFORE )) MB${RST})"
echo
if [ "$RC" = "137" ] && [ $(( MEM_AFTER - MEM_BEFORE )) -gt -50 ]; then
  ok "available 基本未变 —— 内存死在 cgroup 笼子里并已归还，其他服务无感"
  info "  这正是 cgroup OOM 与全局 OOM 最直观的区别；used 甚至可能下降"
fi

# ------------------------------------------------------------------
# 从 dmesg 抓本次的记录（按起始时间之后过滤）
# ------------------------------------------------------------------
hr
echo "内核证据"
hr

# dmesg -T 的时间戳形如 [Sat Nov 21 18:52:03 2026]，按秒级 epoch 过滤更稳：
# 用 dmesg --time-format iso 拿到可比较的 ISO 时间，再交给 awk 比字符串。
OOM_LINE=$(dmesg --time-format iso 2>/dev/null \
  | grep -iE 'killed process|out of memory' \
  | awk -v since="$(date -d "@$START_EPOCH" '+%Y-%m-%dT%H:%M:%S')" '$1 >= since' \
  | tail -1)

if [ -z "$OOM_LINE" ]; then
  # 兜底：环形缓冲里若没有，试 journal 的内核通道
  OOM_LINE=$(journalctl -b -k --since "@$START_EPOCH" 2>/dev/null \
    | grep -iE 'killed process|out of memory' | tail -1)
fi

if [ -n "$OOM_LINE" ]; then
  echo "  ${OOM_LINE#*; }" | sed 's/^/  /'
  echo
  ANON=$(printf '%s' "$OOM_LINE" | grep -oP 'anon-rss:\K[0-9]+' || true)
  TVM=$(printf '%s'  "$OOM_LINE" | grep -oP 'total-vm:\K[0-9]+' || true)
  if printf '%s' "$OOM_LINE" | grep -q 'Memory cgroup out of memory'; then
    hit "首行含 'Memory cgroup' —— 触发域是 cgroup 限额，不是整机耗尽"
  elif printf '%s' "$OOM_LINE" | grep -qE 'Out of memory: Killed'; then
    hit "首行为 'Out of memory'（无 cgroup 前缀）—— 全局 OOM，整机内存已耗尽"
  fi
  if [ -n "$ANON" ]; then
    # 把限额换算成 kB 以便对比（支持 K/M/G 后缀）
    LIM_NUM=$(printf '%s' "$LIMIT" | grep -oP '^[0-9]+')
    LIM_UNIT=$(printf '%s' "$LIMIT" | grep -oP '[A-Za-z]+$' || echo '')
    case "$(printf '%s' "$LIM_UNIT" | tr '[:lower:]' '[:upper:]')" in
      G|GB|GIB) LIM_KB=$(( LIM_NUM * 1024 * 1024 )) ;;
      M|MB|MIB) LIM_KB=$(( LIM_NUM * 1024 )) ;;
      K|KB|KIB) LIM_KB=$(( LIM_NUM )) ;;
      *)        LIM_KB=$(( LIM_NUM / 1024 )) ;;
    esac
    if [ "$LIM_KB" -gt 0 ]; then
      PCT=$(( ANON * 100 / LIM_KB ))
      echo "  anon-rss  : ${ANON} kB ≈ $(( ANON / 1024 )) MiB"
      echo "  限额      : ${LIM_KB} kB ≈ $(( LIM_KB / 1024 )) MiB"
      echo "  占限额    : ${PCT}%"
      echo
      if [ "$PCT" -ge 90 ]; then
        ok "anon-rss 贴着上限（${PCT}%）—— 限额确实生效，进程是撞天花板被杀的"
      else
        warn "anon-rss 仅占 ${PCT}%，限额可能未生效，或内核按其他条件触发"
      fi
    fi
  fi
  [ -n "$TVM" ] && info "  total-vm ${TVM} kB ≈ $(( TVM / 1024 )) MiB 是虚拟地址空间（VSZ），不计入 cgroup，不要用来看占用"
else
  warn "本次运行未在 dmesg / journal 中找到 OOM 记录"
  info "  若退出码是 137，可能是人为 kill -9，或日志已被环形缓冲刷掉"
  info "  手工核对：sudo dmesg -T | grep -i 'killed process' | tail -5"
fi

# ------------------------------------------------------------------
# 收尾
# ------------------------------------------------------------------
hr
echo "收尾"
hr
systemctl reset-failed "$UNIT" 2>/dev/null && echo "  已清理失败单元 $UNIT" || echo "  单元 $UNIT 无需清理"

exit "$RC"
