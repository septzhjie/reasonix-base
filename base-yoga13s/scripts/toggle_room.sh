#!/usr/bin/env bash
#
# toggle_room.sh —— cone-142 适配版：启用/禁用 URL_config.ini 中的直播间（供 cron 定时录制使用）
#
# 用法：
#   toggle_room.sh on  [URL关键字]   # 去掉行首 #，启用监测（开始录制）
#   toggle_room.sh off [URL关键字]   # 加上行首 #，禁用监测（结束录制）
#   toggle_room.sh                   # 查看当前状态（全部行）
#
# 生效时间：DouyinLiveRecorder main.py 每轮循环（120s）重新读配置，改动最多 2 分钟内生效。
# off 只停止"新开线程"，正在录的片段会自然录完（到主播关播为止）。
#
set -euo pipefail

FILE="/opt/1panel/docker/compose/douyu-live/config/URL_config.ini"
LOG="/var/log/recorder_cron.log"
KEY="${2:-}"
MODE="${1:-status}"

if [[ "$MODE" == "status" ]]; then
    python3 - "$FILE" "${KEY:-}" <<'PY'
import sys

file, key = sys.argv[1], sys.argv[2]
with open(file, encoding="utf-8-sig") as f:
    lines = list(f)
if key:
    for line in lines:
        s = line.strip()
        body = s[1:].lstrip() if s.startswith("#") else s
        if key in body and "://" in body:
            print(("已禁用（# 注释，不监测）" if s.startswith("#") else "已启用（正常监测）") + " -> " + body)
            sys.exit(0)
    print("未在文件中找到该 URL 行")
else:
    enabled = []
    for i, line in enumerate(lines, 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        enabled.append(f"行{i}: {s}")
    if enabled:
        print("\n".join(enabled))
    else:
        print("（无启用中的直播间：所有行均为 # 禁用状态）")
PY
    exit 0
fi

case "$MODE" in
  on|off)
    RESULT=$(python3 - "$FILE" "$KEY" "$MODE" <<'PY'
import sys

file, key, mode = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
changed = False
matched = False
with open(file, encoding="utf-8-sig") as f:
    for line in f:
        s = line.strip()
        if s.startswith("#"):
            body = s[1:].lstrip()
        else:
            body = s
        if key in body and "://" in body:
            matched = True
            if mode == "on" and s.startswith("#"):
                out.append(body + "\n")
                changed = True
            elif mode == "off" and not s.startswith("#"):
                out.append("#" + body + "\n")
                changed = True
            else:
                out.append(line)
        else:
            out.append(line)
if not matched:
    print(f"错误: 未在 {file} 中找到包含 '{key}' 的 URL 行", file=sys.stderr)
    sys.exit(1)
if changed:
    with open(file, "w", encoding="utf-8-sig") as f:
        f.writelines(out)
    new_state = "enabled" if mode == "on" else "disabled"
    print(f"[{mode}] {key} -> {new_state} (已写入 {file})")
else:
    print(f"[{mode}] 无变更（当前已是 {'disabled' if mode=='off' else 'enabled'}）")
PY
)
    echo "$RESULT"
    echo "$(date '+%F %T') toggle_room.sh $MODE $KEY | $RESULT" >> "$LOG"
    ;;
  *)
    echo "用法: toggle_room.sh on|off|status [URL关键字]" >&2
    exit 1
    ;;
esac
