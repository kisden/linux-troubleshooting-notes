#!/usr/bin/env bash
# 02-nginx-safe-reload.sh —— 校验通过才 reload，失败自动回滚
# 用法: sudo ./02-nginx-safe-reload.sh [config-path] [health-url]
#       sudo ./02-nginx-safe-reload.sh /etc/nginx/nginx.conf http://127.0.0.1/
#
# 固化五步: 备份 -> nginx -t 闸门 -> 按存活状态选 reload/restart -> HTTP 健康检查 -> 失败回滚

set -uo pipefail
CONF="${1:-/etc/nginx/nginx.conf}"
URL="${2:-http://127.0.0.1/}"
TS=$(date +%Y%m%d-%H%M%S)
BAK="/var/backups/nginx-conf-${TS}.tar.gz"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# 0) 备份当前配置（回滚依赖它）
mkdir -p /var/backups
if tar -czf "$BAK" -C /etc nginx 2>/dev/null; then
  log "[+] 配置已备份: $BAK"
else
  log "[!] 备份失败，中止（不带备份做变更等于赌博）"; exit 1
fi

# 1) 语法校验：唯一闸门
if ! nginx -t -c "$CONF" 2>/tmp/nginx-t.err; then
  log "[!] 配置校验失败，已中止，线上配置未变"
  sed -n '1,5p' /tmp/nginx-t.err
  log "    定位方法: 取报错里的 <file>:<line>，只改那一行，不要通读整份配置"
  exit 1
fi
log "[+] nginx -t 通过"

# 2) 服务存活判断决定 reload 还是 restart
#    reload 依赖 master 进程存活；服务已 failed 时没有对象可发 HUP
if [[ "$(systemctl is-active nginx)" == "active" ]]; then
  log "[*] 服务 active -> reload（不断连接）"
  systemctl reload nginx || { log "[!] reload 失败"; exit 1; }
else
  log "[!] 服务非 active -> reload 无对象可发信号，改用 restart"
  systemctl restart nginx || { log "[!] restart 失败"; exit 1; }
fi

# 3) 健康检查：完成判据是 HTTP 2xx，不是「命令没报错」
sleep 1
if curl -fsS -o /dev/null -m 5 "$URL"; then
  log "[+] 健康检查通过: $URL"
  nginx -v 2>&1 | sed 's/^/    /'
  exit 0
fi

# 4) 回滚
log "[!] 健康检查失败，回滚配置"
tar -xzf "$BAK" -C /etc
nginx -t && systemctl restart nginx
log "[!] 已回滚到 $TS 之前的配置，请人工复核"
exit 1
