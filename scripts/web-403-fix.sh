#!/usr/bin/env bash
# web-403-fix.sh —— 网站根目录 403 定向修复（禁用 777）
# 用法: sudo ./web-403-fix.sh /var/www/html [http://127.0.0.1/]
#
# 只做一件事: 把断点那一级的 x 位 / 文件的 r 位补回来，不做通配 777。

set -uo pipefail
ROOT="${1:-/var/www/html}"
URL="${2:-http://127.0.0.1/}"
SVC_USER="${SVC_USER:-www-data}"
have() { command -v "$1" >/dev/null 2>&1; }

code() { curl -s -o /dev/null -w '%{http_code}' -I "$URL" 2>/dev/null; }

echo "===== [1/5] 当前状态 ====="
BEFORE=$(code); echo "HTTP: $BEFORE"
BEFORE_MODE=$(stat -c '%a %U:%G' -- "$ROOT" 2>/dev/null); echo "根目录: $BEFORE_MODE"
[[ "$BEFORE" == "200" ]] && { echo "已是 200，无需修复"; exit 0; }
[[ "$BEFORE" == "403" ]] || { echo "当前不是 403（$BEFORE），本脚本只处理权限型 403"; exit 1; }

echo
echo "===== [2/5] 服务身份复现 ====="
INDEX=$(sudo -u "$SVC_USER" bash -c "ls -1 '$ROOT' 2>/dev/null | head -1")
echo "目录内首个文件: ${INDEX:-（读不到，目录已不可遍历）}"
if sudo -u "$SVC_USER" test -r "$ROOT" 2>/dev/null; then
  echo "[OK] $SVC_USER 可读根目录 -> 403 可能不是目录权限，转查文件/ACL/AppArmor"
else
  echo "[HIT] $SVC_USER 无法读根目录 -> 目录 x/r 位缺失"
fi

echo
echo "===== [3/5] namei 逐级定位 ====="
namei -l -- "$ROOT" 2>/dev/null | sed 's/^/  /'
BAD=$(namei -l -- "$ROOT" 2>/dev/null | awk 'NR>1 && $1 ~ /^d/ && substr($1,10,1) != "x" {print $NF; exit}')
echo "第一个缺 other-x 的层级: ${BAD:-无}"

echo
echo "===== [4/5] 修复（补位，不给 777）====="
TARGET="${BAD:-$ROOT}"
OLD=$(stat -c '%a' -- "$TARGET")
chmod o+rx -- "$TARGET"
echo "chmod o+rx $TARGET  ($OLD -> $(stat -c '%a' -- "$TARGET"))"

# 文件侧：只补读位，不加执行位
if have find; then
  find "$ROOT" -maxdepth 1 -type f ! -perm -o=r -exec chmod o+r {} \; 2>/dev/null || true
  echo "文件侧已补 o+r（不加执行位）"
fi

echo
echo "===== [5/5] 验证 ====="
AFTER=$(code); echo "HTTP: $AFTER"
if [[ "$AFTER" == "200" ]]; then
  echo "修复成功。根目录现为: $(stat -c '%a %U:%G' -- "$ROOT")"
  echo "记录: $ROOT 原权限 $BEFORE_MODE -> 现 $(stat -c '%a' -- "$ROOT")"
else
  echo "仍为 $AFTER，回滚 $TARGET 到 $OLD"
  chmod "$OLD" -- "$TARGET"
  echo "已回滚。请检查: getfacl / lsattr / dmesg | grep -i apparmor"
  exit 1
fi

echo
echo "===== 基线建议 ====="
echo "  目录 755 root:root | 文件 644 root:root"
echo "  巡检: find /var/www -maxdepth 1 ! -perm 755 -ls"
