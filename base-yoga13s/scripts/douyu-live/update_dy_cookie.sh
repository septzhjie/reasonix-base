#!/usr/bin/env bash
# 更新 douyu-live 的斗鱼 cookie（手动执行）
# 用法: /usr/local/bin/update_dy_cookie.sh
# 1) 从浏览器 douyu.com 复制全部 cookie 串
# 2) 粘贴到提示符（Ctrl-D 结束多行/直接回车一行）
# 3) 脚本写入 config.ini 并重启容器，自动验证是否解锁原画
set -euo pipefail

CONTAINER="douyu-live"
CFG_HOST="/opt/1panel/docker/compose/douyu-live/config/config.ini"
LOG="/var/log/dy_cookie_renew.log"

echo "=== 更新斗鱼 cookie (douyu-live) ==="
echo "请从浏览器(保持登录 douyu.com)复制 cookie 串后粘贴，回车结束："
IFS= read -r -p "cookie> " NEW_COOKIE

# 去除首尾空白
NEW_COOKIE="$(echo "$NEW_COOKIE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

if [ -z "$NEW_COOKIE" ]; then
  echo "错误: cookie 为空，已取消" >&2
  exit 1
fi
# 长度粗校验（正常 cookie 通常 >1000 字符）
if [ "${#NEW_COOKIE}" -lt 500 ]; then
  echo "警告: cookie 仅 ${#NEW_COOKIE} 字符，疑似不完整。仍继续? (y/N)" >&2
  read -r -p "> " yn
  [ "${yn:-n}" = "y" ] || { echo "已取消"; exit 1; }
fi

# 备份
cp "$CFG_HOST" "$CFG_HOST.bak.$(date +%Y%m%d%H%M%S)"

# 写入（RawConfigParser 避免 % 插值问题）
docker exec "$CONTAINER" python3 - "$NEW_COOKIE" <<'PYEOF'
import configparser, sys
path = "/app/config/config.ini"
cookie = sys.argv[1].strip()
cfg = configparser.RawConfigParser()
cfg.read(path, encoding="utf-8")
cfg.set("Cookie", "斗鱼cookie", cookie)
with open(path, "w", encoding="utf-8") as f:
    cfg.write(f)
chk = configparser.RawConfigParser()
chk.read(path, encoding="utf-8")
print("写入完成，新 cookie 长度:", len(chk.get("Cookie", "斗鱼cookie")))
PYEOF

# 重启容器（main.py 只在启动时读一次 cookie）
echo "重启容器 $CONTAINER ..."
cd /opt/1panel/docker/compose/douyu-live
docker compose -f douyu-live.yaml restart "$CONTAINER"
sleep 12

# 验证：取流 rate=0 是否返回原画（无后缀流）
result=$(docker exec "$CONTAINER" python3 -c "
import sys; sys.path.insert(0, '/app')
import asyncio, configparser
from src import spider
RID='6925114'
cfg = configparser.RawConfigParser()
cfg.read('/app/config/config.ini', encoding='utf-8')
cookie = cfg.get('Cookie', '斗鱼cookie')
async def m():
    r = await spider.get_douyu_stream_data(RID, '0', None, cookie)
    d = r.get('data', {})
    live = d.get('rtmp_live', '')
    print(live.split('?')[0].split('/')[-1] if live else str(d)[:80])
asyncio.run(m())
" 2>&1)
echo "取流结果: $result"
if echo "$result" | grep -qE "_900\.flv|error|Error|Traceback"; then
  echo "❌ cookie 更新后仍是低清(_900)或取流失败，请检查 cookie 是否过期/完整" | tee -a "$LOG"
  exit 1
else
  echo "✅ cookie 更新成功，已解锁高画质取流 ($result)" | tee -a "$LOG"
fi