#!/usr/bin/env bash
# port-reach-triage.sh —— 端口可达性分层判定（nc + iptables + tcpdump）
# 用法: sudo ./port-reach-triage.sh <ip> <port> [网卡]
#       sudo ./port-reach-triage.sh 192.168.56.12 80 ens4
#
# 判读: refused=RST(端口没开) / timeout=丢弃(防火墙或路由)

set -uo pipefail
IP="${1:-}"
PORT="${2:-}"
IFACE="${3:-}"
[[ -z "$IP" || -z "$PORT" ]] && { echo "用法: $0 <ip> <port> [iface]"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "===== [1] nc 探活（最快的分类器）====="
if have nc; then
  OUT=$(nc -zv -w 3 "$IP" "$PORT" 2>&1); RC=$?
  echo "$OUT"
  case "$OUT" in
    *succeeded*|*open*) echo "[结论] 端口可达，网络与服务都正常" ;;
    *refused*)          echo "[结论] refused -> 对方回了 RST，端口没人监听（查 ss -lntp / systemctl）" ;;
    *timed*|*"in progress"*) echo "[结论] timeout -> 包被静默丢弃（查 iptables / 路由 / 安全组）" ;;
    *) echo "[结论] 返回码 $RC，输出未归类" ;;
  esac
else
  echo "（nc 未安装）"
fi

echo
echo "===== [2] 本机监听（仅在目标机上有意义）====="
ss -lntp 2>/dev/null | grep -E ":${PORT}\b" || echo "  本机无 $PORT 监听（若当前就在目标机上，说明服务未起）"

echo
echo "===== [3] iptables 计数（规则存在 ≠ 命中）====="
if have iptables && [[ $EUID -eq 0 ]]; then
  iptables -vnL INPUT --line-numbers 2>/dev/null | head -8
  echo "  --> 让对端再连一次，对比 pkts 是否增长；增长才是命中"
else
  echo "  （需 root 或 iptables 不可用）"
fi

echo
echo "===== [4] 抓包命令（另开窗口执行）====="
IF="${IFACE:-$(ip -br link 2>/dev/null | awk 'NR==1{print $1}')}"
echo "  sudo tcpdump -i ${IF} -nn 'tcp port ${PORT}' -c 20"
echo "  只有 SYN、无 SYN-ACK  -> DROP"
echo "  SYN 后立刻 RST        -> 端口没开"
echo "  SYN + SYN-ACK         -> 网络没问题，往应用层查"

echo
echo "===== [5] 路由出口 ====="
have ip && ip route get "$IP" 2>/dev/null | sed 's/^/  /'
