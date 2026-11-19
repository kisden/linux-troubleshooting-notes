#!/usr/bin/env bash
# perm-denied-triage.sh —— Permission denied 六因一次性排查
# 用法: sudo ./perm-denied-triage.sh <path> [service-user]
#       sudo ./perm-denied-triage.sh /var/www/html/index.html www-data
#
# 输出顺序 = 命中概率从高到低，第一个 [HIT] 基本就是根因。

set -uo pipefail
TARGET="${1:-}"
SVC_USER="${2:-}"
[[ -z "$TARGET" ]] && { echo "用法: $0 <path> [service-user]"; exit 2; }
[[ -e "$TARGET" ]] || { echo "路径不存在: $TARGET"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "===== 目标 ====="
ls -ld -- "$TARGET"

echo
echo "===== [1] 目录链逐级权限（namei）====="
echo "--> 从上往下读，停在第一个缺 x 的层级；末行报「文件权限不够」通常是父目录的锅"
namei -l -- "$TARGET" 2>/dev/null || echo "（namei 不可用）"

# 自动挑出第一个 other 无 x 的父目录
BAD=$(namei -l -- "$TARGET" 2>/dev/null | awk 'NR>1 && $1 ~ /^d/ && substr($1,10,1) != "x" {print; exit}')
[[ -n "${BAD:-}" ]] && echo "[HIT-1] 目录缺 other 的 x 位: $BAD"

echo
echo "===== [2] 属主 / 属组 ====="
stat -c '属主=%U(%u) 属组=%G(%g) 权限=%A' -- "$TARGET" 2>/dev/null
[[ -n "$SVC_USER" ]] && id "$SVC_USER" 2>/dev/null

echo
echo "===== [3] 服务身份复现（决定性一步）====="
if [[ -n "$SVC_USER" ]]; then
  if sudo -u "$SVC_USER" test -r -- "$TARGET" 2>/dev/null; then
    echo "[OK] $SVC_USER 可读 -> 不是 DAC 问题，继续看 4/5/6"
  else
    echo "[HIT-3] $SVC_USER 读不到 -> 权限问题成立（DAC 层）"
  fi
else
  echo "（未指定 service-user，跳过；建议传 www-data / nginx / postgres 等）"
fi

echo
echo "===== [4] ACL ====="
if have getfacl; then
  ACL=$(getfacl -p -- "$TARGET" 2>/dev/null | grep -E '^(user|group|mask|other):.*:[rwx-]*[^rwx-]|^mask::' || true)
  getfacl -p -- "$TARGET" 2>/dev/null | sed -n '1,12p'
  [[ -n "${ACL:-}" ]] && echo "[HIT-4] ACL 存在额外条目或 mask 收紧"
else
  echo "（getfacl 未安装：apt install acl）"
fi

echo
echo "===== [5] 文件属性 ====="
if have lsattr; then
  ATTR=$(lsattr -d -- "$TARGET" 2>/dev/null | awk '{print $1}')
  echo "attr=$ATTR"
  [[ "$ATTR" == *i* || "$ATTR" == *a* ]] && echo "[HIT-5] 存在 i/a 属性，chmod 无效，需 chattr -i / -a"
fi

echo
echo "===== [6] 强制访问控制（AppArmor）====="
if have dmesg; then
  AA=$(sudo dmesg 2>/dev/null | grep -i 'apparmor.*DENIED' | tail -3 || true)
  echo "${AA:-（最近无 AppArmor DENIED 记录）}"
fi

echo
echo "===== [7] 挂载选项 ====="
MP=$(df --output=target -- "$TARGET" 2>/dev/null | tail -1)
echo "挂载点: ${MP:-未知}"
[[ -n "${MP:-}" ]] && mount | grep -E "on ${MP} " | head -2

echo
echo "===== 结论 ====="
echo "1) 目录缺 x  -> chmod o+x <该级目录>（或整级 755）"
echo "2) 属主不对  -> chown <svc-user>:<svc-group> <path>"
echo "3) ACL 拒绝  -> setfacl -x <条目> <path>"
echo "4) 属性锁    -> chattr -i <path>"
echo "5) AppArmor  -> aa-complain <profile> 或调整 profile 规则"
echo "6) 挂载限制  -> 重挂 rw / 去掉 noexec"
