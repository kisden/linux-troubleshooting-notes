#!/usr/bin/env bash
# net-layer-triage.sh —— 四层逐段探测，定位「打不开」卡在哪一层
# 用法: ./net-layer-triage.sh <url> [上游DNS]
#       ./net-layer-triage.sh https://example.com 8.8.8.8
#
# 逻辑: 每层通过才进下一层; 第一个失败层即为结论, 不再往下跑。

set -uo pipefail
URL="${1:-}"
UPSTREAM="${2:-}"
[[ -z "$URL" ]] && { echo "用法: $0 <url> [upstream-dns]"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

# 从 URL 里拆出 host / port / scheme
HOST=$(printf '%s' "$URL" | sed -E 's#^[a-z]+://##; s#/.*$##; s#:.*$##')
SCHEME=$(printf '%s' "$URL" | sed -E 's#^([a-z]+)://.*#\1#')
PORT=$(printf '%s' "$URL" | sed -nE 's#^[a-z]+://[^:/]+:([0-9]+).*#\1#p')
if [[ -z "$PORT" ]]; then
  [[ "$SCHEME" == "https" ]] && PORT=443 || PORT=80
fi

echo "目标: $URL"
echo "解析: host=$HOST port=$PORT scheme=$SCHEME"
echo

echo "===== ① DNS ====="
if ! getent hosts "$HOST" >/dev/null 2>&1; then
  echo "[FAIL] getent 解析失败（应用视角）"
  have dig && dig "$HOST" +time=2 +tries=1 | sed -n '1,8p'
  if [[ -n "$UPSTREAM" ]]; then
    echo "--- 对照: dig @$UPSTREAM ---"
    if dig "@$UPSTREAM" "$HOST" +short +time=2 +tries=1 | grep -qE '^[0-9]'; then
      echo "[结论] 网络与上游正常 -> 本机解析配置坏（resolv.conf / hosts / nsswitch）"
      dig "@$UPSTREAM" "$HOST" +short | sed 's/^/    /'
    else
      echo "[结论] 换上游也失败 -> 网络层问题，往 ② 查"
    fi
  else
    echo "[提示] 传第二个参数（上游 DNS）可自动做对照"
  fi
  exit 1
fi
echo "[OK] $(getent hosts "$HOST" | head -1)"
if [[ -n "$UPSTREAM" ]] && have dig; then
  SYS=$(getent hosts "$HOST" | awk '{print $1}' | head -1)
  REAL=$(dig "@$UPSTREAM" "$HOST" +short +time=2 +tries=1 | grep -E '^[0-9]' | head -1)
  if [[ -n "$REAL" && "$SYS" != "$REAL" ]]; then
    echo "[!] 系统解析=$SYS 但上游=$REAL -> 存在 hosts / 本地覆盖"
  fi
fi
echo

echo "===== ② TCP ====="
if have nc; then
  OUT=$(nc -zv -w 3 "$HOST" "$PORT" 2>&1)
  RC=$?
  echo "$OUT"
  if [[ $RC -ne 0 ]]; then
    case "$OUT" in
      *refused*) echo "[结论] refused -> 端口没人听：查 ss -lntp / systemctl status" ;;
      *timed*|*"in progress"*) echo "[结论] timeout -> 包被丢：查 iptables -vnL 的 pkts 与 tcpdump 有无 SYN-ACK" ;;
      *) echo "[结论] 未知失败，返回码 $RC" ;;
    esac
    exit 1
  fi
else
  echo "（nc 未安装，跳过）"
fi
echo

echo "===== ③ TLS ====="
if [[ "$SCHEME" == "https" ]]; then
  if have openssl; then
    DATES=$(echo | openssl s_client -connect "$HOST:$PORT" -servername "$HOST" 2>/dev/null \
            | openssl x509 -noout -dates -subject 2>/dev/null)
    if [[ -z "$DATES" ]]; then
      echo "[FAIL] 取不到证书 -> 握手失败或不是 TLS 服务"
      exit 1
    fi
    echo "$DATES" | sed 's/^/  /'
    echo "当前时间: $(date -u '+%b %e %H:%M:%S %Y GMT')"
    NOT_AFTER=$(echo "$DATES" | sed -n 's/^notAfter=//p')
    if [[ -n "$NOT_AFTER" ]] && [[ $(date -d "$NOT_AFTER" +%s 2>/dev/null || echo 0) -lt $(date +%s) ]]; then
      echo "[结论] 证书已过期 -> 续签；若时间异常先查 date / chronyc"
      exit 1
    fi
    echo "[OK] 证书在有效期内"
  fi
else
  echo "（非 https，跳过）"
fi
echo

echo "===== ④ HTTP ====="
if have curl; then
  curl -sS -o /dev/null -w '状态码: %{http_code}  总耗时: %{time_total}s\n' --max-time 10 "$URL"
  curl -sS -I --max-time 10 "$URL" 2>/dev/null | sed -n '1,6p'
else
  echo "（curl 未安装）"
fi
