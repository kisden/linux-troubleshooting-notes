#!/usr/bin/env bash
# hosts-drift-check.sh —— /etc/hosts 基线与异常条目检查
# 用法: ./hosts-drift-check.sh [基线文件]
#       ./hosts-drift-check.sh /var/lib/baseline/hosts.sha256
#
# 无基线文件时: 生成基线并打印当前指纹（首次运行）
# 有基线文件时: 比对，不一致返回 1

set -uo pipefail
HOSTS=/etc/hosts
BASE="${1:-}"
have() { command -v "$1" >/dev/null 2>&1; }

CUR=$(sha256sum "$HOSTS" 2>/dev/null | awk '{print $1}')
echo "===== 当前指纹 ====="
echo "  sha256: $CUR"
echo "  mtime : $(stat -c '%y' "$HOSTS" 2>/dev/null)"

echo
echo "===== 有效条目（非注释）====="
grep -vE '^\s*(#|$)' "$HOSTS" 2>/dev/null | nl -ba | sed 's/^/  /'

echo
echo "===== 可疑条目 ====="
# 公网域名被指向回环/内网，是 hosts 劫持或演练残留的典型形态
SUS=$(awk '!/^[[:space:]]*#/ && NF>=2 {
        ip=$1;
        for(i=2;i<=NF;i++){
          h=$i;
          if (h ~ /\.(com|net|org|cn|io|edu)$/ && (ip ~ /^127\./ || ip ~ /^10\./ || ip ~ /^192\.168\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./))
            print "  " ip "  " h "   <- 公网域名指向内网/回环"
        }
      }' "$HOSTS" 2>/dev/null)
[[ -z "$SUS" ]] && echo "  （未发现）" || echo "$SUS"

echo
echo "===== 与解析结果对照 ====="
for d in $(awk '!/^[[:space:]]*#/ && NF>=2 {for(i=2;i<=NF;i++) print $i}' "$HOSTS" 2>/dev/null | head -5); do
  printf '  %-32s getent: %s\n' "$d" "$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)"
done

echo
if [[ -z "$BASE" ]]; then
  echo "===== 未指定基线文件 ====="
  echo "  首次运行，可保存当前指纹作为基线："
  echo "    sudo mkdir -p /var/lib/baseline && echo '$CUR  /etc/hosts' | sudo tee /var/lib/baseline/hosts.sha256"
  exit 0
fi

if [[ ! -f "$BASE" ]]; then
  echo "[FAIL] 基线文件不存在: $BASE"
  exit 2
fi
OLD=$(awk '{print $1}' "$BASE" | head -1)
echo "===== 基线比对 ====="
echo "  基线: $OLD"
echo "  当前: $CUR"
if [[ "$OLD" == "$CUR" ]]; then
  echo "[OK] 未变更"
  exit 0
else
  echo "[ALERT] /etc/hosts 已变更，请核对上面的条目列表"
  exit 1
fi
