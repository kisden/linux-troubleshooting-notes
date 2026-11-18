#!/usr/bin/env bash
# 02-unit-audit.sh —— systemd unit 静态体检
# 用法: sudo ./02-unit-audit.sh <service-name>
#       sudo ./02-unit-audit.sh nginx
#
# 针对「手工执行成功、systemctl 失败」的场景:
# 逐项验证 User / ExecStart / WorkingDirectory / Type / Restart，
# 提前命中 217/USER、203/EXEC、200/CHDIR 这类 unit 层故障。

set -uo pipefail
SVC="${1:-}"
[[ -z "$SVC" ]] && { echo "用法: $0 <service-name>"; exit 2; }

UNIT_TXT=$(systemctl cat "$SVC" 2>/dev/null) || {
  echo "[!] unit 不存在: ${SVC}.service"; exit 1; }

echo "===== ${SVC}.service 片段来源 ====="
echo "$UNIT_TXT" | grep '^#' || true
echo

get() { echo "$UNIT_TXT" | grep -m1 "^$1=" | cut -d= -f2-; }

FAIL=0
check() { # $1=name $2=OK|FAIL $3=detail
  if [[ "$2" == "OK" ]]; then printf '  [ OK ] %-18s %s\n' "$1" "$3"
  else printf '  [FAIL] %-18s %s\n' "$1" "$3"; FAIL=$((FAIL+1)); fi
}

echo "===== 字段体检 ====="

# 1) User
U=$(get User)
if [[ -z "$U" ]]; then
  check "User" "OK" "未指定 -> 以 root 运行（安全基线建议显式指定）"
elif getent passwd "$U" >/dev/null 2>&1; then
  check "User" "OK" "$U 存在"
else
  check "User" "FAIL" "$U 不存在 -> 会报 217/USER"
fi

# 2) ExecStart：必须绝对路径 + 存在 + 可执行
ES=$(get ExecStart | sed -E 's/^-//; s/ .*//')
if [[ -z "$ES" ]]; then
  check "ExecStart" "FAIL" "未配置"
elif [[ "$ES" != /* ]]; then
  check "ExecStart" "FAIL" "'$ES' 非绝对路径（systemd 不做 PATH 查找）-> 203/EXEC"
elif [[ ! -e "$ES" ]]; then
  check "ExecStart" "FAIL" "$ES 不存在 -> 203/EXEC"
elif [[ ! -x "$ES" ]]; then
  check "ExecStart" "FAIL" "$ES 无 x 位 -> 203/EXEC"
else
  check "ExecStart" "OK" "$ES 可执行"
fi

# 3) WorkingDirectory
WD=$(get WorkingDirectory)
if [[ -n "$WD" && ! -d "$WD" ]]; then
  check "WorkingDirectory" "FAIL" "$WD 不存在 -> 200/CHDIR"
else
  check "WorkingDirectory" "OK" "${WD:-未指定（使用 /）}"
fi

# 4) Type 与 Restart
T=$(get Type)
check "Type" "OK" "${T:-simple（默认）}"
R=$(get Restart)
if [[ -z "$R" || "$R" == "no" ]]; then
  check "Restart" "FAIL" "未配置自愈 -> 崩溃后不自恢复"
else
  check "Restart" "OK" "$R$(get RestartSec | sed 's/^/ , RestartSec=/')"
fi

# 5) Environment 条目数 —— 登录 shell 与 systemd 的差异来源
ENVN=$(get Environment | wc -w)
echo "  [INFO] Environment= 条目数: ${ENVN}（0 表示 systemd 只给最小环境，PATH 需显式声明）"

echo
echo "===== 当前运行态 ====="
printf '  is-active   : %s\n' "$(systemctl is-active "$SVC")"
printf '  NRestarts   : %s\n' "$(systemctl show "$SVC" -p NRestarts --value)"
printf '  MainPID     : %s\n' "$(systemctl show "$SVC" -p MainPID --value)"
echo "  Process 行  : $(systemctl status "$SVC" -l --no-pager 2>&1 | grep -c 'ExecStart') 条（1=前置失败, 2=程序失败）"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "结论: unit 静态检查全部通过，故障可能在程序内部或资源层（端口/权限/证书）"
else
  echo "结论: 命中 ${FAIL} 项 unit 缺陷，先修 unit 再查程序（改完记得 systemctl daemon-reload）"
fi
