#!/usr/bin/env bash
# 检查 douyu-live 的斗鱼 cookie 剩余有效期；剩 <=2 天时写提醒日志并发邮件通知
set -euo pipefail

CONTAINER="${1:-douyu-live}"
CFG="/opt/1panel/docker/compose/douyu-live/config/config.ini"
LOG="/var/log/dy_cookie_renew.log"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-2}"

# ---- 邮件通知（可被环境变量覆盖，便于 cron 或免改脚本）----
NOTIFY_EMAIL="${NOTIFY_EMAIL:-1211875002@qq.com}"
SEND_MAIL="${SEND_MAIL:-/usr/local/bin/send-ali-mail.sh}"

# 发送邮件（失败不中断主流程，仅记日志）；send-ali-mail.sh 不存在则跳过
notify() {  # $1=主题  $2=正文
    local subject="$1" body="$2"
    if [ ! -x "$SEND_MAIL" ]; then
        echo "[$(date "+%F %T")] 邮件通知跳过：未找到 $SEND_MAIL（可设置 SEND_MAIL）" >> "$LOG"
        return 0
    fi
    if "$SEND_MAIL" -s "$subject" -b "$body" "$NOTIFY_EMAIL" >> "$LOG" 2>&1; then
        echo "[$(date "+%F %T")] 邮件通知已发送 → $NOTIFY_EMAIL" >> "$LOG"
    else
        echo "[$(date "+%F %T")] 邮件通知发送失败 → $NOTIFY_EMAIL（详见上方日志）" >> "$LOG"
    fi
}

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
  NO_COOKIE)
    echo "[$(date "+%F %T")] 警告: douyu-live 斗鱼cookie 为空（将录制 540p）" >> "$LOG"
    notify "⚠️ [$(hostname)] douyu-live 斗鱼cookie 为空" \
"douyu-live 容器的斗鱼 cookie 为空，将降级为 540p 录制。

请尽快更新：ssh $(hostname) '/usr/local/bin/update_dy_cookie.sh'
（浏览器 douyu.com 登录 → F12 → Application → Cookies 复制全部 cookie 串）"
    ;;
  NO_JWT|PARSE_ERR)
    echo "[$(date "+%F %T")] 警告: douyu-live cookie 缺少/无法解析 acf_jwt_token" >> "$LOG"
    notify "⚠️ [$(hostname)] douyu-live cookie 异常" \
"douyu-live 的 cookie 缺少 acf_jwt_token 或无法解析，将无法使用高画质取流。

请尽快更新：ssh $(hostname) '/usr/local/bin/update_dy_cookie.sh'"
    ;;
  *)
    days="$result"
    echo "[$(date "+%F %T")] douyu-live 斗鱼cookie 剩余 ${days} 天" >> "$LOG"
    if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)" "$days" "$THRESHOLD_DAYS"; then
      echo "[$(date "+%F %T")] ⚠️ 斗鱼cookie 将于 ${days} 天后过期，请尽快更新！运行: /usr/local/bin/update_dy_cookie.sh" >> "$LOG"
      notify "⚠️ [$(hostname)] douyu-live 斗鱼cookie 将于 ${days} 天后过期" \
"douyu-live 容器的斗鱼 cookie 剩余 ${days} 天过期（阈值 ${THRESHOLD_DAYS} 天）。

请尽快更新：ssh $(hostname) '/usr/local/bin/update_dy_cookie.sh'
（浏览器 douyu.com 登录 → F12 → Application → Cookies 复制全部 cookie 串）
过期后即使未更新，也仍可匿名录制（仅 540p），不会中断。"
    fi
    ;;
esac