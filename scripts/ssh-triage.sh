#!/usr/bin/env bash
# ssh-triage.sh —— SSH 连不上分层判定
# 用法: sudo ./ssh-triage.sh [refused|timeout|denied]
#       sudo ./ssh-triage.sh refused
#
# 分层逻辑: refused=传输层 / timeout=网络层 / denied=认证层

set -uo pipefail
MODE="${1:-all}"
PORT_HINT="${SSH_PORT:-22}"
have() { command -v "$1" >/dev/null 2>&1; }

section() { echo; echo "===== $* ====="; }

section "[0] 服务与监听（所有分支都要先看这个）"
systemctl is-active ssh 2>/dev/null | sed 's/^/ssh.service: /'
systemctl is-active ssh.socket 2>/dev/null | sed 's/^/ssh.socket:  /'

LISTEN=$(sudo ss -lntp 2>/dev/null | grep -E "sshd|systemd" | grep -E ":${PORT_HINT}\b|:22\b|:2222\b" || true)
if [[ -z "$LISTEN" ]]; then
  echo "[HIT] 22/2222 无监听 -> 客户端必然是 refused"
  echo "      下一步: journalctl -u ssh -n 30 看为什么没起来（常见: /run/sshd 缺失）"
else
  echo "$LISTEN"
  echo "--> 判读: users 是 sshd = 常驻（backlog 128）；是 systemd pid=1 = socket 激活（backlog 4096）"
fi

if [[ "$MODE" == "refused" || "$MODE" == "all" ]]; then
  section "[A/B] refused 分支：谁在听、听哪个端口"
  sudo sshd -T 2>/dev/null | grep -iE '^(port|listenaddress|allowusers|denyusers|permitrootlogin)' || echo "（sshd -T 失败，服务可能没起）"
  echo "--> 期望 port 与客户端一致；不一致就是 B 改端口"
  echo "--> 期望 ss 里是 sshd 监听；若是 systemd(pid=1)，注意 stop/改端口都不按直觉走"
fi

if [[ "$MODE" == "timeout" || "$MODE" == "all" ]]; then
  section "[C] timeout 分支：包是不是被丢了"
  if have iptables; then
    sudo iptables -vnL INPUT --line-numbers 2>/dev/null | head -10
    echo "--> 关键: 让客户端再连一次，看 pkts 是否增长（增长=规则命中）"
  fi
  echo "抓包命令（另开一个窗口跑，然后让客户端连一次）:"
  echo "  sudo tcpdump -i \$(ip -br link | awk 'NR==1{print \$1}') -nn 'tcp port ${PORT_HINT}' -c 5"
  echo "--> 只有 SYN、无 SYN-ACK = DROP；有 RST = REJECT；有 SYN-ACK = 网络没问题"
fi

if [[ "$MODE" == "denied" || "$MODE" == "all" ]]; then
  section "[D] denied 分支：认证策略"
  sudo sshd -T 2>/dev/null | grep -iE '^(allowusers|denyusers|denygroups|allowgroups|passwordauthentication|pubkeyauthentication)' || true
  echo "--> AllowUsers 一旦出现，未列出的用户全部被拒（注意: 它也会挡住 root）"
  echo "前置条件: is-active ssh 必须 active，且 ss 里必须能看到 sshd，否则客户端到不了认证层"
fi

section "恢复顺序（固定四步）"
echo "  1) mkdir -p /run/sshd        # 常驻模式必需"
echo "  2) systemctl restart ssh"
echo "  3) ss -lntp | grep :22       # 验监听，别跳过"
echo "  4) 客户端 ssh -v 试连"
