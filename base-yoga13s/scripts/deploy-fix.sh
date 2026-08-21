#!/usr/bin/env bash
#
# deploy-fix.sh —— 部署斗鱼取流修复到服务器 yoga13（幂等）
#
# 功能：
#   1. 本地修复文件 docs/spider.py.patched → 服务器 /opt/1panel/docker/compose/code_overlay/src/spider.py
#      （md5 相同则跳过上传）
#   2. 确保 compose 含 code_overlay 挂载行（不存在则幂等添加，先备份）
#   3. 重建容器并等待启动
#   4. 验证：容器内 md5 与 overlay 一致 + 日志无 ERROR + 最近日志正常
#
# 用法：
#   ./scripts/deploy-fix.sh            # 部署 + 验证
#   ./scripts/deploy-fix.sh --check    # 只检查现状（md5 对账 / 挂载 / 容器状态），不部署
#
# 依赖：本地有 ssh 访问 yoga13（root），服务器有 docker compose。

set -euo pipefail

SSH_TARGET="${SSH_TARGET:-yoga13}"
COMPOSE_DIR="/opt/1panel/docker/compose"
COMPOSE_FILE="${COMPOSE_DIR}/douyin-live-recorder.yaml"
OVERLAY_DIR="${COMPOSE_DIR}/code_overlay/src"
OVERLAY_FILE="${OVERLAY_DIR}/spider.py"
LOCAL_PATCH="$(cd "$(dirname "$0")/.." && pwd)/docs/spider.py.patched"
CONTAINER="live"

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail ]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 前置检查 ----------
[ -f "$LOCAL_PATCH" ] || die "本地补丁文件不存在: $LOCAL_PATCH"
command -v ssh >/dev/null || die "需要 ssh"

# 服务器连通性
ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" 'echo ok' >/dev/null 2>&1 \
  || die "无法连接 $SSH_TARGET（检查 ssh 配置）"

local_md5=$(md5 -q "$LOCAL_PATCH" 2>/dev/null || md5sum "$LOCAL_PATCH" | awk '{print $1}')
server_md5=$(ssh "$SSH_TARGET" "md5sum $OVERLAY_FILE 2>/dev/null | awk '{print \$1}'" || true)

mount_present=$(ssh "$SSH_TARGET" "grep -c 'code_overlay/src/spider.py' $COMPOSE_FILE 2>/dev/null || true")
container_running=$(ssh "$SSH_TARGET" "docker ps --filter name=$CONTAINER --format '{{.Status}}' 2>/dev/null || true")

log "本地补丁 md5 : $local_md5"
log "服务器 overlay md5: ${server_md5:-<不存在>}"
log "compose 挂载行  : ${mount_present:-0} 处"
log "容器状态        : ${container_running:-<无>}"

# ---------- --check 模式 ----------
if [ "${1:-}" = "--check" ]; then
  echo
  [ "${server_md5:-}" = "$local_md5" ] && ok "overlay 已是最新" || warn "overlay 与本地不一致（或缺失）→ 需部署"
  [ "${mount_present:-0}" -ge 1 ] && ok "compose 含挂载行" || warn "compose 缺少挂载行 → 需部署"
  [ -n "$container_running" ] && ok "容器运行中: $container_running" || warn "容器未运行"
  exit 0
fi

if [ "${1:-}" != "" ]; then
  die "未知参数: ${1:-}（仅支持 --check）"
fi

# ---------- 1. 上传 overlay（幂等） ----------
if [ "${server_md5:-}" = "$local_md5" ]; then
  log "overlay 已是最新，跳过上传"
else
  log "上传补丁到 $OVERLAY_FILE ..."
  cat "$LOCAL_PATCH" | base64 | ssh "$SSH_TARGET" "base64 -d > \"$OVERLAY_FILE\""
  new_md5=$(ssh "$SSH_TARGET" "md5sum '$OVERLAY_FILE' | awk '{print \$1}'")
  [ "$new_md5" = "$local_md5" ] && ok "上传完成，md5 一致" || die "上传后 md5 不一致: $new_md5"
fi

# ---------- 2. 确保 compose 含挂载行（幂等，先备份） ----------
if [ "${mount_present:-0}" -ge 1 ]; then
  log "compose 已含挂载行，跳过修改"
else
  log "compose 备份 + 添加挂载行 ..."
  ssh "$SSH_TARGET" "
    [ -f '$COMPOSE_FILE.bak' ] || cp '$COMPOSE_FILE' '$COMPOSE_FILE.bak'
    python3 - <<'PY'
import re
p = '$COMPOSE_FILE'
s = open(p).read()
anchor = '      - ./downloads:/app/downloads'
add = anchor + '\n      - ./code_overlay/src/spider.py:/app/src/spider.py'
if 'code_overlay/src/spider.py' not in s:
    assert anchor in s, '未找到 downloads 挂载锚点'
    s = s.replace(anchor, add, 1)
    open(p, 'w').write(s)
    print('compose 已更新')
else:
    print('compose 无需修改')
PY
  "
  ssh "$SSH_TARGET" "grep -c 'code_overlay/src/spider.py' '$COMPOSE_FILE'" >/dev/null \
    && ok "挂载行已就位" || die "挂载行添加失败"
fi

# ---------- 3. 重建容器 ----------
log "重建容器 $CONTAINER ..."
ssh "$SSH_TARGET" "cd '$COMPOSE_DIR' && docker compose -f douyin-live-recorder.yaml up -d --force-recreate" \
  | tail -5
sleep 5

# ---------- 4. 验证 ----------
log "验证部署结果："
echo

new_server_md5=$(ssh "$SSH_TARGET" "md5sum '$OVERLAY_FILE' | awk '{print \$1}'")
container_md5=$(ssh "$SSH_TARGET" "docker exec $CONTAINER md5sum /app/src/spider.py 2>/dev/null | awk '{print \$1}'" || true)
if [ "$new_server_md5" = "$local_md5" ] && [ "$container_md5" = "$local_md5" ]; then
  ok "容器内 /app/src/spider.py 与本地补丁 md5 一致（$local_md5）"
else
  warn "md5 不一致! overlay=$new_server_md5 容器内=${container_md5:-<无法读取>} 本地=$local_md5"
fi

container_running=$(ssh "$SSH_TARGET" "docker ps --filter name=$CONTAINER --format '{{.Status}}'")
[ -n "$container_running" ] && ok "容器运行中: $container_running" || warn "容器未运行"

sleep 60
err_count=$(ssh "$SSH_TARGET" "docker logs --since 2m $CONTAINER 2>&1 | grep -c 'ERROR' || true")
if [ "${err_count:-0}" -eq 0 ]; then
  ok "近 2 分钟日志无 ERROR"
else
  warn "近 2 分钟日志有 $err_count 条 ERROR，请进一步检查"
  ssh "$SSH_TARGET" "docker logs --since 2m $CONTAINER 2>&1 | grep 'ERROR' | tail -5"
fi

echo
log "部署流程结束。录制产物可查看: ssh $SSH_TARGET 'ls -laR $COMPOSE_DIR/downloads/'"