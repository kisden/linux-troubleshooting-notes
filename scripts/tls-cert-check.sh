#!/usr/bin/env bash
# tls-cert-check.sh —— 远程/本地证书体检（s_client + x509）
# 用法: ./tls-cert-check.sh <host> [port] [警告天数]
#       ./tls-cert-check.sh 127.0.0.1 443 30
#
# 退出码: 0=正常 1=即将过期 2=已过期 3=取不到证书

set -uo pipefail
HOST="${1:-}"
PORT="${2:-443}"
WARN_DAYS="${3:-30}"
[[ -z "$HOST" ]] && { echo "用法: $0 <host> [port] [warn-days]"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }
have openssl || { echo "openssl 未安装"; exit 3; }

echo "===== 证书信息: $HOST:$PORT ====="
RAW=$(echo | timeout 10 openssl s_client -connect "$HOST:$PORT" -servername "$HOST" 2>/dev/null)
if [[ -z "$RAW" ]]; then
  echo "[FAIL] 连接或握手失败（端口不通？不是 TLS 服务？）"
  exit 3
fi

INFO=$(printf '%s' "$RAW" | openssl x509 -noout -subject -issuer -dates 2>/dev/null)
if [[ -z "$INFO" ]]; then
  echo "[FAIL] 拿到了连接但解析不出证书"
  exit 3
fi
echo "$INFO" | sed 's/^/  /'

# 验证链结果（自签会在这里暴露）
VERIFY=$(printf '%s' "$RAW" | grep -E 'Verify return code' | tail -1)
echo "  ${VERIFY:-（无 Verify return code 行）}"

NOT_AFTER=$(echo "$INFO" | sed -n 's/^notAfter=//p')
NOT_BEFORE=$(echo "$INFO" | sed -n 's/^notBefore=//p')
NOW=$(date +%s)
EXP=$(date -d "$NOT_AFTER" +%s 2>/dev/null || echo 0)
STA=$(date -d "$NOT_BEFORE" +%s 2>/dev/null || echo 0)

if [[ $EXP -eq 0 ]]; then
  echo "[WARN] notAfter 解析失败，请手工核对: $NOT_AFTER"
  exit 1
fi

DAYS=$(( (EXP - NOW) / 86400 ))
echo
echo "  当前时间 : $(date -u '+%b %e %H:%M:%S %Y GMT')"
echo "  生效时间 : $NOT_BEFORE"
echo "  到期时间 : $NOT_AFTER"
echo "  剩余天数 : $DAYS 天"

if [[ $NOW -lt $STA ]]; then
  echo "[FAIL] 尚未生效（notBefore 在未来）-> 检查系统时间是否偏慢"
  exit 2
elif [[ $NOW -gt $EXP ]]; then
  echo "[FAIL] 已过期 -> 续签；若刚续签，先核对 date / chronyc"
  exit 2
elif [[ $DAYS -lt $WARN_DAYS ]]; then
  echo "[WARN] 剩余 $DAYS 天（阈值 $WARN_DAYS）-> 安排续签"
  exit 1
else
  echo "[OK] 证书有效"
  exit 0
fi
