#!/usr/bin/env bash
# ssh-socket-mode.sh —— ssh 在 socket 激活 / 常驻模式之间切换
# 用法: sudo ./ssh-socket-mode.sh status       # 看当前谁持有 22
#       sudo ./ssh-socket-mode.sh standalone   # 切常驻（改 Port 前必须做）
#       sudo ./ssh-socket-mode.sh socket       # 还原 Ubuntu 出厂行为
#
# 模式差异只在一件事：谁持有监听套接字。

set -uo pipefail
have() { command -v "$1" >/dev/null 2>&1; }
need_root() { [[ $EUID -eq 0 ]] || { echo "请用 sudo 运行"; exit 1; }; }

show_status() {
  echo "===== 当前监听 ====="
  ss -lntp 2>/dev/null | grep -E 'sshd|systemd' | grep -E ':22\b|:2222\b' || echo "（22 无监听）"
  echo
  echo "===== unit 状态 ====="
  printf '%-22s' "ssh.service";  systemctl is-active ssh
  printf '%-22s' "ssh.socket";   systemctl is-active ssh.socket
  printf '%-22s' "socket enabled"; systemctl is-enabled ssh.socket 2>/dev/null || true
  echo
  echo "===== 判读 ====="
  if ss -lntp 2>/dev/null | grep -E ':22\b' | grep -q 'users:(("systemd"'; then
    echo "模式: socket 激活（backlog 4096，sshd 按连接拉起）"
    echo "注意: stop ssh 不会关端口；sshd_config 里的 Port 不生效"
  elif ss -lntp 2>/dev/null | grep -E ':22\b|:2222\b' | grep -q 'users:(("sshd"'; then
    echo "模式: 常驻（backlog 128，sshd -D 按 sshd_config 监听）"
  else
    echo "模式: 无监听，sshd 未运行"
  fi
}

to_standalone() {
  need_root
  echo "===== [1/4] 停并禁用 socket ====="
  systemctl stop ssh.socket 2>/dev/null || true
  systemctl disable ssh.socket 2>&1 | sed 's/^/  /'
  echo
  echo "===== [2/4] 补 privilege separation 目录 ====="
  mkdir -p /run/sshd && chmod 755 /run/sshd && echo "  /run/sshd 就绪"
  echo
  echo "===== [3/4] 语法闸门 + 重启 ====="
  sshd -t || { echo "配置语法错误，中止"; exit 1; }
  systemctl restart ssh || { echo "restart 失败"; journalctl -u ssh -n 10 --no-pager; exit 1; }
  sleep 2
  echo
  echo "===== [4/4] 验证 ====="
  show_status
  echo
  echo "提示: 此时 sshd_config 里的 Port 才真正生效"
}

to_socket() {
  need_root
  echo "===== [1/3] 启用并启动 socket ====="
  systemctl enable --now ssh.socket 2>&1 | sed 's/^/  /'
  echo
  echo "===== [2/3] 重启服务 ====="
  systemctl restart ssh
  sleep 2
  echo
  echo "===== [3/3] 验证 ====="
  show_status
  echo
  echo "提示: 已还原出厂行为；此时 sshd_config 的 Port 不再决定监听端口"
}

case "${1:-status}" in
  status)     show_status ;;
  standalone) to_standalone ;;
  socket)     to_socket ;;
  *) echo "用法: $0 {status|standalone|socket}"; exit 2 ;;
esac
