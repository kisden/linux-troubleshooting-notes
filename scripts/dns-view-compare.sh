#!/usr/bin/env bash
# dns-view-compare.sh —— 三视角对照，暴露 hosts / 存根污染
# 用法: ./dns-view-compare.sh <域名> [上游DNS...]
#       ./dns-view-compare.sh www.ubuntu.com 10.0.2.3 8.8.8.8
#
# 判读: getent 与 dig 一致、但与 @上游 不同 -> hosts 或本地覆盖
#       getent 有、dig 无 -> nsswitch 走了 files
#       三者全不同 -> 多个解析路径并存，逐个排查

set -uo pipefail
DOMAIN="${1:-}"
shift || true
UPSTREAMS=("$@")
[[ -z "$DOMAIN" ]] && { echo "用法: $0 <域名> [上游DNS...]"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

hr() { printf '%.0s-' {1..64}; echo; }

echo "===== ① getent（应用视角，走 nsswitch）====="
G=$(getent hosts "$DOMAIN" 2>/dev/null)
if [[ -z "$G" ]]; then
  echo "  （无结果，退出码 $?）"
else
  echo "$G" | sed 's/^/  /'
fi
hr

if have dig; then
  echo "===== ② dig 默认（问 127.0.0.53 存根，会合并 hosts）====="
  D=$(dig "$DOMAIN" +short +time=2 +tries=1 2>/dev/null)
  [[ -z "$D" ]] && echo "  （无结果；可能是存根不可用）" || echo "$D" | sed 's/^/  /'
  hr

  if [[ ${#UPSTREAMS[@]} -gt 0 ]]; then
    for U in "${UPSTREAMS[@]}"; do
      echo "===== ③ dig @$U（直问上游，纯 DNS）====="
      R=$(dig "@$U" "$DOMAIN" +short +time=2 +tries=1 2>/dev/null)
      [[ -z "$R" ]] && echo "  （无结果；该上游不可达或域名不存在）" || echo "$R" | sed 's/^/  /'
      hr
    done
  else
    echo "===== ③ 未指定上游，跳过纯 DNS 对照 ====="
    echo "  提示: 加一个上游 DNS 才能区分「DNS 记录改了」和「本地文件覆盖了」"
    hr
  fi
else
  echo "（dig 未安装：apt install dnsutils）"
fi

echo "===== 解析配置 ====="
ls -l /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
grep -E '^hosts:' /etc/nsswitch.conf 2>/dev/null | sed 's/^/  /'
have resolvectl && resolvectl status 2>/dev/null | grep -E 'Link|DNS Server|Current DNS' | sed 's/^/  /'
grep -vE '^\s*(#|$)' /etc/hosts 2>/dev/null | sed 's/^/  hosts: /'

echo
echo "===== 判读 ====="
echo "  getent 与 dig 一致、但 @上游 不同  -> hosts 或存根覆盖（查 /etc/hosts）"
echo "  getent 有、dig 无                -> nsswitch 的 files 命中，DNS 侧没有这条记录"
echo "  三者全不同                        -> 多条解析路径并存，逐个隔离"
