#!/usr/bin/env bash
# 检查 douyu-live 的斗鱼 cookie 剩余有效期；剩 <=2 天时写提醒日志
set -euo pipefail

CONTAINER="${1:-douyu-live}"
CFG="/opt/1panel/docker/compose/douyu-live/config/config.ini"
LOG="/var/log/dy_cookie_renew.log"
THRESHOLD_DAYS=2

docker ps --format "{{.Names}}" | grep -qx "$CONTAINER" || { echo "[$(date "+%F %T")] 容器 $CONTAINER 不存在，跳过" >> "$LOG"; exit 0; }
[ -f "$CFG" ] || { echo "[$(date "+%F %T")] 配置文件不存在 $CFG" >> "$LOG"; exit 0; }

result=$(docker exec "$CONTAINER" python3 -c "
import configparser, re, base64, json, time, sys
cfg = configparser.RawConfigParser()
cfg.read('/app/config/config.ini', encoding='utf-8')
cookie = cfg.get('Cookie', '斗鱼cookie')
if not cookie:
    print('NO_COOKIE'); sys.exit(0)
m = re.search(r'acf_jwt_token=([^;]+)', cookie)
if not m:
    print('NO_JWT'); sys.exit(0)
try:
    payload = m.group(1).split('.')[1]
    payload += '=' * (-len(payload) % 4)
    data = json.loads(base64.urlsafe_b64decode(payload))
    exp = int(data.get('exp', 0))
except Exception:
    print('PARSE_ERR'); sys.exit(0)
now = int(time.time())
print(f'{(exp - now) / 86400.0:.1f}')
")

case "$result" in
  NO_COOKIE) echo "[$(date "+%F %T")] 警告: douyu-live 斗鱼cookie 为空（将录制 540p）" >> "$LOG" ;;
  NO_JWT|PARSE_ERR) echo "[$(date "+%F %T")] 警告: douyu-live cookie 缺少/无法解析 acf_jwt_token" >> "$LOG" ;;
  *)
    days="$result"
    echo "[$(date "+%F %T")] douyu-live 斗鱼cookie 剩余 ${days} 天" >> "$LOG"
    if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)" "$days" "$THRESHOLD_DAYS"; then
      echo "[$(date "+%F %T")] ⚠️ 斗鱼cookie 将于 ${days} 天后过期，请尽快更新！运行: /usr/local/bin/update_dy_cookie.sh" >> "$LOG"
    fi
    ;;
esac