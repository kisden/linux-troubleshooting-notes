#!/usr/bin/env bash
# 02-service-triage.sh —— 服务三步法一键采集
# 用法: sudo ./02-service-triage.sh <service-name>
#       sudo ./02-service-triage.sh nginx
#
# 设计依据: status 给分类(起没起来) -> journalctl 给位置(哪行) -> 手工验证给归因(配置/端口/权限)

set -uo pipefail
SVC="${1:-}"
[[ -z "$SVC" ]] && { echo "用法: $0 <service-name>"; exit 2; }

echo "===== [1/4] systemctl status (分类) ====="
systemctl status "$SVC" -l --no-pager 2>&1 | sed -n '1,20p'

echo
echo "===== [1b] Process 行与退出码 ====="
# 条数决定病因层：1 行=没跑到主程序；2 行=跑到主程序后失败
PROC=$(systemctl status "$SVC" -l --no-pager 2>&1 | grep -E '^\s*(Process|Main PID|Status):' || true)
echo "${PROC:-（未采集到 Process 行）}"
PROC_CNT=$(echo "$PROC" | grep -c 'ExecStart')
echo "--> ExecStart 相关行数: ${PROC_CNT}（1=配置/前置失败, 2=程序自身失败）"

echo
echo "===== [2/4] journalctl 首条 error (定位) ====="
FIRST=$(journalctl -u "$SVC" -n 200 --no-pager 2>/dev/null \
        | grep -m1 -iE 'emerg|error|failed|denied|bind\(\)' || true)
echo "${FIRST:-（最近 200 行未匹配到 error/emerg）}"
echo "--> 注意: 首条才是根因, 后续行多为连锁反应"

echo
echo "===== [3/4] 生效的 unit 片段 (来源) ====="
systemctl cat "$SVC" 2>/dev/null \
  | grep -E '^(#|User=|ExecStart|ExecStartPre|WorkingDirectory|Type=|Environment=|Restart=)' || true

echo
echo "===== [4/4] 手工验证 (归因) ====="
BIN=$(systemctl cat "$SVC" 2>/dev/null | grep -m1 '^ExecStart=' | sed -E 's/^ExecStart=-?//; s/ .*//')
echo "ExecStart 二进制: ${BIN:-未知}"
if [[ -n "${BIN}" && -x "${BIN}" ]]; then
  case "$(basename "$BIN")" in
    nginx)  echo "--- nginx -t ---";  "${BIN}" -t 2>&1 ;;
    sshd)   echo "--- sshd -t ---";   "${BIN}" -t 2>&1 ;;
    httpd)  echo "--- httpd -t ---";  "${BIN}" -t 2>&1 ;;
    *)      echo "--- 无内置 -t 校验，直接试运行 ---"; timeout 5 "${BIN}" --version 2>&1 | head -2 ;;
  esac
else
  echo "[!] ExecStart 不存在或不可执行 -> 疑似 203/EXEC"
fi

# 从 unit 里抽出监听端口，检查是否被占
PORTS=$(systemctl cat "$SVC" 2>/dev/null | grep -oE ':(80|443|[0-9]{4,5})\b' | tr -d ':' | sort -u | head -5)
for P in $PORTS; do
  echo "--- ss :${P} ---"
  ss -lntp "sport = :${P}" 2>/dev/null || ss -lntp | grep ":${P} "
done

echo
echo "===== 初步结论 ====="
if [[ "${PROC_CNT}" -le 1 ]]; then
  echo "配置/前置层失败 -> 看 nginx -t 输出定位行号，改完再 restart"
else
  echo "程序已执行 -> 若 -t 通过则是端口/权限问题；-t 失败则是配置问题"
fi
echo "存活判据: systemctl is-active ${SVC} = $(systemctl is-active "$SVC" 2>/dev/null)"
