# douyu-live 专用斗鱼录制容器 + cookie 续签方案

> 建立日期：2026-08-19 ｜ 适用服务器：yoga13（root）
> 关联文档：`douyu-stream-fix.md`（斗鱼取流修复：匿名取流会被降级为 540p，需携带 cookie）、`cron-scheduled-recording.md`（定时录制操作手册，方案 A）
> 脚本位置：`scripts/douyu-live/`（与线上 `/usr/local/bin/` 同步的最新副本 + compose）

## 1. 为什么需要 douyu-live

现有 `live` 容器（DouyinLiveRecorder）是**多平台通用**录制，配置里混着抖音/快手/虎牙/B站等一堆 cookie。斗鱼有特殊性：

1. **取流必须带有效 cookie**，否则被降级为 540p（见 `douyu-stream-fix.md` 第 9 节）
2. cookie 约 **7 天过期**（JWT `acf_jwt_token`），需要定期换
3. cookie 是**登录态、敏感信息**，不希望和录其他平台混在一起、被误清

因此新建**专用容器 `douyu-live`**：数据/配置完全独立，专注斗鱼房间；配一套**半自动 cookie 续签**工具（到期提醒 + 一键更新）。

## 2. 架构总览

```
                    ┌──────────────────────────┐
                    │   douyu-live 容器          │
                    │  (ihmily/douyin-live-     │
                    │   recorder:latest)        │
                    │   ├ /app/config           │
                    │   ├ /app/downloads        │
                    │   └ /app/src/spider.py    │ ← overlay 修复版(含cookie补丁)
                    └──────────┬───────────────┘
                               │ 读 config.ini 斗鱼cookie
                               │
   ┌───────────────────────────┼───────────────────────────┐
   │ 主动                        被动                          │
   │ 手动开关录制                   每日 cron 检查                │
   │ douyu-live/config/           check_dy_cookie.sh           │
   │ URL_config.ini 加/去 #        剩≤2天写日志提醒               │
   └───────────────────────────┼───────────────────────────┘
                               │
                    update_dy_cookie.sh（手动换cookie）
                    写config.ini → 重启容器 → 验证取流
```

## 3. 容器部署

### 3.1 目录结构

```
/opt/1panel/docker/compose/douyu-live/
├── douyu-live.yaml            # compose（工作区 scripts/douyu-live/ 有副本）
├── config/
│   ├── config.ini             # 只含斗鱼cookie，其余平台清空，推送关闭
│   └── URL_config.ini         # 房间列表（行首#=禁用）
├── logs/
├── downloads/                 # 录制产物
├── backup_config/
└── code_overlay/src/spider.py # 修复版（md5 ba102ac，含 cookie 补丁）
```

### 3.2 compose 文件（`douyu-live.yaml`）

```yaml
services:
  douyu-live:
    container_name: douyu-live
    image: ihmily/douyin-live-recorder:latest
    environment:
      - TERM=xterm-256color
    tty: true
    stdin_open: true
    volumes:
      - ./config:/app/config
      - ./logs:/app/logs
      - ./backup_config:/app/backup_config
      - ./downloads:/app/downloads
      - ./code_overlay/src/spider.py:/app/src/spider.py
    restart: always
```

### 3.3 部署 / 启停

```bash
ssh yoga13 'cd /opt/1panel/docker/compose/douyu-live && docker compose -f douyu-live.yaml up -d'   # 首次部署/更新后启动
ssh yoga13 'cd /opt/1panel/docker/compose/douyu-live && docker compose -f douyu-live.yaml restart douyu-live'  # 重启（改 overlay/cookie 后必须）
ssh yoga13 'docker logs --tail 20 douyu-live'
ssh yoga13 'docker ps --filter name=douyu-live'
```

> ⚠️ 改 `/app` 内代码（overlay）或 cookie 后**必须重启容器**：`python main.py` 只在启动时读一次配置/加载模块，不重启不生效（见 `douyu-stream-fix.md` 9.3 的教训）。

## 4. 录制房间管理

### 4.1 URL_config.ini 格式

每行：`直播间URL,画质: 名称`，行首 `#` = 禁用（不监测不录），无 `#` = 启用（开播即录）。当前：

```ini
#https://www.douyu.com/6925114,原画: 轰轰仔
```

- 画质可选：`原画|蓝光|超清|高清|标清|流畅`（映射见 `douyu-stream-fix.md`）
- `main.py` 每 120s 重读一次文件，改动最多 2 分钟生效

### 4.2 开/关录制

> ⚠️ **`/usr/local/bin/toggle_room.sh` 硬编码的是 `live` 容器的路径**（`/opt/1panel/docker/compose/config/URL_config.ini`），对 douyu-live **无效**！操作 douyu-live 请直接编辑它的 URL_config.ini。

```bash
# 开启（去掉行首#）
ssh yoga13 'sed -i "s|^#https://www.douyu.com/6925114|https://www.douyu.com/6925114|" /opt/1panel/docker/compose/douyu-live/config/URL_config.ini'
# 关闭（加上行首#）
ssh yoga13 'sed -i "s|^https://www.douyu.com/6925114|#https://www.douyu.com/6925114|" /opt/1panel/docker/compose/douyu-live/config/URL_config.ini'
# 查状态
ssh yoga13 'docker exec douyu-live cat /app/config/URL_config.ini'
# 查录制行为
ssh yoga13 'docker logs --since 5m douyu-live | grep -E "传入地址|正在录制|没有正在"'
# 查产物
ssh yoga13 'ls -laR /opt/1panel/docker/compose/douyu-live/downloads/'
```

> 注意文件开头有 BOM（`\ufeff`），用上面的 `sed`（匹配行首 `#` 前不涉及 BOM 位置）可行；若直接 `^#` 匹配失败，改用 python 处理。

## 5. cookie 续签方案（半自动）

### 5.1 为什么半自动

- 斗鱼 JWT（`acf_jwt_token`）约 **7 天过期**（payload `exp` 决定）
- **无公开刷新接口**——JWT 由服务端签发，只能浏览器重新登录/刷新页面拿到新 cookie
- 所以：**必须人做的事**（浏览器复制 cookie）留给人，**能自动化的都自动化**（记住时间、提醒、写入、重启、验证）

### 5.2 工具清单

| 工具 | 线上位置 | 工作区副本 | 作用 |
|---|---|---|---|
| 检查脚本 | `/usr/local/bin/check_dy_cookie.sh` | `scripts/douyu-live/check_dy_cookie.sh` | 解析 JWT `exp`，剩 ≤2 天写告警日志 |
| 更新脚本 | `/usr/local/bin/update_dy_cookie.sh` | `scripts/douyu-live/update_dy_cookie.sh` | 交互粘贴新 cookie → 写入 → 重启 → 验证 |
| compose | `/opt/1panel/docker/compose/douyu-live/douyu-live.yaml` | `scripts/douyu-live/douyu-live.yaml` | 容器编排 |

检查/更新脚本**默认目标容器 douyu-live**，cron 已安装：

```cron
0 9 * * * /usr/local/bin/check_dy_cookie.sh
```

日志文件：`/var/log/dy_cookie_renew.log`

### 5.3 日常巡检（自动）

每天 9:00 自动写一行日志，例如：

```
[2026-08-19 16:41:57] douyu-live 斗鱼cookie 剩余 6.3 天
```

剩余 ≤2 天时追加告警（提醒人工换）：

```
[2026-08-19 16:42:01] ⚠️ 斗鱼cookie 将于 6.3 天后过期，请尽快更新！运行: /usr/local/bin/update_dy_cookie.sh
```

查看：`ssh yoga13 'cat /var/log/dy_cookie_renew.log'`

阈值可用 `THRESHOLD_DAYS` 变量调整（脚本第 10 行）。

### 5.4 手动换 cookie（约 1 分钟）

```bash
ssh yoga13 '/usr/local/bin/update_dy_cookie.sh'
```

脚本流程：
1. 提示粘贴 cookie → 浏览器打开 douyu.com（保持登录）→ F12 → Application → Cookies → 复制全部（`dy_did` ~ `Hm_lpvt_*`）
2. 回车 → 自动：备份 config.ini → `RawConfigParser` 写入 `斗鱼cookie` → **重启容器** → 取流验证
3. 验证通过：`✅ cookie 更新成功，已解锁高画质取流 (6925114rIDrEEuKo.flv)`（无后缀=原画）
   失败：`❌ ... 仍是低清(_900)`（cookie 过期/不完整），需重试

> 关键点都内置在脚本里，无需手动记得：**写入后必须重启容器**（main.py 只在启动时读一次 cookie）；验证看流文件名是否有 `_900`（有=降级）。

### 5.5 cookie 过期后的行为

- cookie 过期/留空 → 程序**回退匿名取流**，仍能录但**只有 540p**（`_900` 档），不会崩
- 所以即使漏了续签，也只是画质降级，不会丢录制

## 6. 常见问题排查

| 症状 | 排查 |
|---|---|
| 录出来 540p | 1) `cat /var/log/dy_cookie_renew.log` 看剩余天数；2) 可能 cookie 过期 → 跑 `update_dy_cookie.sh`；3) 改完后确认容器已重启 |
| 改了 spider.py 不生效 | 容器没重启（overlay 只改文件，需 `docker compose restart douyu-live`）|
| 开了录制没反应 | 检查 URL_config.ini 行首是否还有 `#`；最多等 2 分钟（120s 轮询）|
| toggle_room.sh 对 douyu-live 无效 | 它只操作 live 容器的 URL_config（见 4.2），用直接编辑方式 |

## 7. 相关参考

- 斗鱼取流修复细节（匿名降级原理、cookie 补丁、spider.py 改动）：`douyu-stream-fix.md`
- live 容器定时录制（toggle_room.sh + crontab 方案）：`cron-scheduled-recording.md`