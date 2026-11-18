#!/usr/bin/env bash
# 02-port-owner-trace.sh —— 端口占用四步溯源
# 用法: sudo ./02-port-owner-trace.sh <port>
#       sudo ./02-port-owner-trace.sh 80
#
# 输出四要素: 进程名 / 运行用户 / 启动时间 / 真实二进制
# 第 4 步是关键: 进程名与 cmdline 可伪装, /proc/PID/exe 由内核维护

set -uo pipefail
PORT="${1:-}"
[[ -z "$PORT" ]] && { echo "用法: $0 <port>"; exit 2; }

echo "===== 目标端口: ${PORT} ====="

echo
echo "--- [1] ss 谁在监听 ---"
ss -lntpH "sport = :${PORT}" 2>/dev/null || ss -lntp | grep -w ":${PORT}"

PIDS=$(ss -lntpH "sport = :${PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u)
# 兜底: 旧版 ss 不支持过滤表达式
[[ -z "$PIDS" ]] && PIDS=$(ss -lntp | grep -w ":${PORT}" | grep -oP 'pid=\K[0-9]+' | sort -u)

if [[ -z "$PIDS" ]]; then
  echo "[!] 端口 ${PORT} 无监听者（可能未启动，或仅处于非 LISTEN 状态）"
  ss -antp 2>/dev/null | grep -w ":${PORT}" || true
  exit 0
fi
echo "--> 监听 PID: $(echo $PIDS | tr '\n' ' ')"

echo
echo "--- [2] 完整持有者交叉验证 ---"
if command -v lsof >/dev/null 2>&1; then
  lsof -nP -i :"${PORT}" 2>/dev/null || echo "(lsof 无输出)"
else
  echo "(lsof 未安装: apt install lsof)"
fi
if command -v fuser >/dev/null 2>&1; then
  echo -n "fuser -n tcp ${PORT}: "; fuser -n tcp "${PORT}" 2>/dev/null; echo
fi

for PID in $PIDS; do
  echo
  echo "===== PID ${PID} 详情 ====="
  echo "--- [3] 启动时间 / 父进程 / 用户 ---"
  ps -o pid,ppid,user,lstart,etime,cmd -p "$PID" 2>/dev/null || echo "(进程已退出)"

  echo "--- [4] 真实二进制 (内核维护, 无法伪装) ---"
  ls -l "/proc/${PID}/exe" 2>/dev/null || echo "(无权限或进程已退出, 需 root)"
  echo -n "readlink: "; readlink -f "/proc/${PID}/exe" 2>/dev/null || echo "N/A"

  echo "--- 辅助: cmdline / cwd / 环境差异 ---"
  echo -n "cmdline: "; tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null; echo
  echo -n "cwd    : "; readlink -f "/proc/${PID}/cwd" 2>/dev/null || echo "N/A"
  echo -n "状态   : "; awk '/^State|^PPid|^Uid/{print}' "/proc/${PID}/status" 2>/dev/null | tr '\n' ' '; echo

  echo "--- 结论四要素 ---"
  PNAME=$(cat "/proc/${PID}/comm" 2>/dev/null || echo "unknown")
  PUSER=$(ps -o user= -p "$PID" 2>/dev/null | tr -d ' ')
  PSTART=$(ps -o lstart= -p "$PID" 2>/dev/null)
  PEXE=$(readlink -f "/proc/${PID}/exe" 2>/dev/null)
  printf '进程名: %s\n运行用户: %s\n启动时间: %s\n真实二进制: %s\n' \
    "$PNAME" "${PUSER:-?}" "${PSTART:-?}" "${PEXE:-?}"
done
