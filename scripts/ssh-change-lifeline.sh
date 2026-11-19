#!/usr/bin/env bash
# ssh-change-lifeline.sh —— 改 SSH 配置前的保险绳 + 应用 + 自动回滚
# 用法: sudo ./ssh-change-lifeline.sh check       # 只体检，不改任何东西
#       sudo ./ssh-change-lifeline.sh apply       # 备份+埋绳+重启+验监听
#       sudo ./ssh-change-lifeline.sh rollback    # 手动回滚
#
# 设计前提: 本脚本不能保证你不断线，只能保证断了之后能自己回来。

set -uo pipefail
CONF=/etc/ssh/sshd_config
BAK=/etc/ssh/sshd_config.wb-bak
DELAY="${LIFELINE_DELAY:-300}"     # 秒，默认 5 分钟
have() { command -v "$1" >/dev/null 2>&1; }

need_root() { [[ $EUID -eq 0 ]] || { echo "请用 sudo 运行"; exit 1; }; }

do_check() {
  echo "===== 保险绳体检 ====="
  printf '%-28s' "1. 控制台"; echo "请自行确认 VMware 窗口能登录（脚本无法代验）"
  printf '%-28s' "2. atd 状态"; systemctl is-active atd
  printf '%-28s' "3. 队列中的任务"; atq 2>/dev/null | wc -l
  printf '%-28s' "4. sshd 语法"; if sshd -t 2>/dev/null; then echo "OK"; else echo "FAIL"; fi
  printf '%-28s' "5. 当前监听"; ss -lntp 2>/dev/null | grep -cE ':22\b' | sed 's/^/监听行数 /'
  printf '%-28s' "6. 当前 IP"; ip -4 -o addr show scope global | awk '{print $4}' | paste -sd, -
  echo
  echo "--> 第 2 项必须 active；第 3 项建议 >=1；第 4 项必须 OK"
}

do_apply() {
  need_root
  have at || { echo "at 未安装: apt install at"; exit 1; }
  systemctl is-active --quiet atd || { echo "atd 未运行，保险绳不可用，中止"; exit 1; }

  echo "===== [1/5] 备份 ====="
  cp -a "$CONF" "$BAK" && echo "已备份 -> $BAK"

  echo "===== [2/5] 语法闸门 ====="
  if ! sshd -t; then
    echo "sshd -t 失败，不重启。配置未生效，服务仍在运行。"
    exit 1
  fi
  echo "语法 OK"

  echo "===== [3/5] 埋保险绳（${DELAY}s 后回滚）====="
  echo "sleep ${DELAY} && cp -a ${BAK} ${CONF} && mkdir -p /run/sshd && systemctl restart ssh" \
    | at now 2>&1 | tail -2
  atq | tail -3
  echo "--> 若要取消: sudo atrm \$(sudo atq | awk '{print \$1}')"

  echo "===== [4/5] 重启 ====="
  mkdir -p /run/sshd && chmod 755 /run/sshd
  systemctl restart ssh || { echo "restart 失败，立即回滚"; do_rollback; exit 1; }
  sleep 2

  echo "===== [5/5] 验监听 ====="
  if ss -lntp 2>/dev/null | grep -qE ':22\b.*sshd|:22\b.*systemd'; then
    ss -lntp | grep -E ':22\b'
    echo "监听正常。请在【新窗口】试连，成功后再取消保险绳："
    echo "  sudo atrm \$(sudo atq | awk '{print \$1}')"
  else
    echo "22 端口无监听 -> 自动回滚"
    do_rollback
    exit 1
  fi
}

do_rollback() {
  need_root
  if [[ -f "$BAK" ]]; then
    cp -a "$BAK" "$CONF"
    mkdir -p /run/sshd && chmod 755 /run/sshd
    systemctl restart ssh
    ss -lntp | grep -E ':22\b' || echo "回滚后仍无监听，请用控制台"
  else
    echo "没有备份文件 $BAK"
  fi
  atq 2>/dev/null | awk '{print $1}' | xargs -r sudo atrm 2>/dev/null || true
}

case "${1:-check}" in
  check)    do_check ;;
  apply)    do_apply ;;
  rollback) do_rollback ;;
  *) echo "用法: $0 {check|apply|rollback}"; exit 2 ;;
esac
