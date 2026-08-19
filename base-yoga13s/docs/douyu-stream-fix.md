# 斗鱼直播取流修复记录（2026-08-18）

> 适用范围：DouyinLiveRecorder v4.0.7（ihmily/douyin-live-recorder:latest），容器 `live`，由 1Panel + docker compose 部署在服务器 `yoga13`。
>
> ⚠️ **2026-08-19 更新：原 `live` 容器已删除**，斗鱼录制迁移到专用容器 `douyu-live`（`/opt/1panel/docker/compose/douyu-live/`，含同样 overlay 修复版 spider.py）。本文修复内容对 `douyu-live` 同样适用（md5 一致），日常运维见 `douyu-live-container.md`。

## 1. 症状

- 容器本身正常（`Up`，无重启/OOM），但日志每 2 分钟（监测轮询间隔）报一次错误：
  ```
  ERROR - 错误信息: 'NoneType' object has no attribute 'group' 发生错误的行数: 639
  ```
- 状态栏显示"没有正在录制的直播"，永远录不到任何内容。

## 2. 根因

### 2.1 直接原因

`main.py` 第 639 行是 `asyncio.run(stream.get_douyu_stream_url(...))`（斗鱼取流分支），异常冒泡到外层 `except`（`main.py:1607`）被记录。

取流链路：`get_douyu_info_data()`（拿房间信息，正常）→ `stream.get_douyu_stream_url()` → `spider.get_douyu_stream_data()` → `spider.get_token_js()`。

**`get_token_js()` 的旧逻辑**：抓取 `https://www.douyu.com/{rid}` 页面，用正则
`r'(vdwdae325w_64we[\s\S]*function ub98484234[\s\S]*?)function'` 提取加密 JS，再用 `execjs` 执行生成签名。

斗鱼页面改版后**不再包含 `vdwdae325w_64we` / `ub98484234` 这段加密代码**，`re.search()` 返回 `None`，`.group(1)` 抛 `AttributeError: 'NoneType' object has no attribute 'group'`。

### 2.2 排查中的两个坑（避免日后重踩）

1. **`trace_error_decorator` 是同步装饰器**，包住 async 函数时只捕获协程对象创建、捕不到函数体里的异常——异常会直接冒泡到 `main.py` 的外层 `except`，所以行号总是 639 而非 spider.py 内部行。
2. **配置里的旧斗鱼 cookie（`config.ini` 的 `斗鱼cookie`，约 2776 字符）已过期**。取流接口 `getH5PlayV1` 不校验登录，但**带上过期 cookie 反而返回 `鉴权失败`**。排查时一度误以为签名算法不对，实际是 cookie 的锅——不带 cookie 就好。

## 3. 新版签名算法（逆向成果）

逆向来源：生产页面动态加载的 `web-encrypt-*.js`
（`https://shark2.douyucdn.cn/front-publish/douyu-web-first-stream-master/web-encrypt-{hash}.js`）。

### 3.1 取流流程

```
1) GET https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption?did={did}
   → data: { key, rand_str, enc_time, expire_at, is_special, enc_data, cpp }

2) 计算签名（stream 类型）：
   ts = int(time.time())                     # 秒级
   o  = ""  if is_special == 1 else f"{rid}{ts}"
   u  = rand_str
   repeat enc_time 次:  u = md5(u + key)
   auth = md5(u + key + o)

3) POST https://www.douyu.com/lapi/live/getH5PlayV1/{rid}
   headers: Content-Type: application/x-www-form-urlencoded, Referer: https://www.douyu.com/{rid}
   body（手动拼接，不 URL 编码，与 web-encrypt JS 一致）:
     enc_data={enc_data}&tt={ts}&did={did}&auth={auth}
     &ver=Douyu_new&rate={rate}&hevc=0&fa=0&ive=1

   rate: 0蓝光 / 3超清 / 2高清 / -1默认
   成功返回 data.rtmp_url + data.rtmp_live（结构兼容旧代码，stream.py 无需改）
```

### 3.2 did 取值

- 无登录时默认 `10000000000000000000000000001501`
- 或取 cookie 里的 `dy_did` 值

## 4. 改了什么

只改了 `/app/src/spider.py`（在容器镜像内），两个函数：

| 函数 | 旧实现（失效） | 新实现 |
|---|---|---|
| `get_token_js()` | 抓 HTML + execjs 执行旧加密 JS | 调 `getEncryption` 接口 + 纯 Python md5 签名，返回 dict `{enc_data, tt, did, auth}` |
| `get_douyu_stream_data()` | 旧 `getH5Play` 接口 + 旧 sign 参数 | 新 `getH5PlayV1` 接口 + 手动拼接 form body；**不传 cookie** |

其余代码（`get_douyu_info_data`、`stream.py` 等）未改动。

## 5. 持久化方式（关键）

容器 `/app` 目录本身**没有挂载**，重建容器会丢失代码改动。因此：

- **宿主机放修复文件**：`/opt/1panel/docker/compose/code_overlay/src/spider.py`（md5 与容器内一致）
- **compose 挂载覆盖单个文件**（`/opt/1panel/docker/compose/douyin-live-recorder.yaml`）：
  ```yaml
  volumes:
    - ./code_overlay/src/spider.py:/app/src/spider.py
  ```
- 原 compose 备份：`/opt/1panel/docker/compose/douyin-live-recorder.yaml.bak`

这样 1Panel 面板或 `docker compose up` 重建容器后，修复依然生效。

## 6. 验证过程（命令即证据）

```bash
# 全链路（信息 + 取流）返回真实流地址
docker exec live sh -c "cd /app && python3 -c '...'"   # get_douyu_info_data → get_douyu_stream_url
# → PORT: {... "flv_url": "https://stream-...edgesrv.com:443/live/5551871rusOwlUmM_900.flv?wsAuth=...&ver=Douyu_new ..."}

# 生产确认：日志 0 ERROR + 真实录制文件产出
ssh yoga13 'docker logs live | grep -c ERROR'          # → 0
ssh yoga13 'ls -laR /opt/1panel/docker/compose/downloads/'
# → downloads/斗鱼直播/Minana呀/Minana呀_2026-08-18_23-35-14.mp4（持续增长）
```

## 7. 重新验证 / 故障排查手册

若之后又出问题（斗鱼再改版、或清理时误删 overlay），按此顺序排查：

```bash
# 1. 版本与容器状态
ssh yoga13 'docker ps --filter name=live'
# 2. 看错误
ssh yoga13 'docker logs --since 1h live | grep ERROR'
# 3. 确认 overlay 挂载生效（md5 一致才说明挂载 OK）
ssh yoga13 'md5sum /opt/1panel/docker/compose/code_overlay/src/spider.py'
ssh yoga13 'docker exec live md5sum /app/src/spider.py'
# 4. 手动复现取流（在容器内），打印真实异常
ssh yoga13 'docker exec live sh -c "cd /app && python3 - <<PY
import asyncio, json
from src import spider
async def m():
    try:
        r = await spider.get_douyu_stream_data(\"5551871\", \"-1\", None, None)
        print(type(r), json.dumps(r, ensure_ascii=False)[:200] if not isinstance(r, str) else r[:100])
    except Exception as e:
        import traceback; traceback.print_exc()
asyncio.run(m())
PY"'

# 5. 若报"鉴权失败/时间戳错误"：
#    a. 确认请求里没带 cookie（新代码已去掉）
#    b. 抓最新 web-encrypt JS，比对签名算法是否变化
#    c. 确认 did / tt 时间窗口
```

## 8. 恢复原始代码（万一需要）

```bash
# 在宿主机上操作：
ssh yoga13 '
  cp /opt/1panel/docker/compose/code_overlay/src/spider.py /tmp/spider.patched.bak.py   # 先留底
  rm /opt/1panel/docker/compose/code_overlay/src/spider.py                               # 删掉 overlay 文件
  # 编辑 compose，去掉 volumes 里的 code_overlay 那一行
  cd /opt/1panel/docker/compose && docker compose -f douyin-live-recorder.yaml up -d --force-recreate
'
# 容器重建后 /app/src/spider.py 恢复为镜像内原始版本
```

## 9. cookie 补丁（2026-08-19）—— 匿名取流会被降级为 540p

### 9.1 背景与根因

**症状**：配置 `原画` 录制，产物却始终是 960×540（25fps，~300kbps），文件名带"原画"但画质不对。

**根因**：第 2.2 节"不带 cookie 就好"只解决了签名失效问题，但**丢掉了登录态**。斗鱼 `getH5PlayV1` 接口对**匿名请求会降级为单一 `_900`（960×540）档**，所有 `rate`（0/2/3/-1）都返回同一个低档流。新版 `spider.py` 的 `get_douyu_stream_data` 形参有 `cookies` 却从未使用（旧版注释"不要透传 cookie"），导致**配置了 cookie 的房间也无法解锁高画质**。

**验证对照**（实测房间 6925114「轰轰仔」，2026-08-19）：

| rate | 匿名（修复前） | 带 cookie（修复后） |
|---|---|---|
| 0（原画） | `_900.flv` → 960×540 / 25fps / ~0.3Mbps | **无后缀.flv → 2560×1440 / 60fps / ~8.8Mbps** |
| 3（超清） | `_900.flv` → 960×540 | `_2000.flv` → 1280×720 |
| -1（默认） | `_900.flv` → 960×540 | `_4000.flv` → 1920×1080 |

> 流文件名中的 `_900/_2000/_4000` 即斗鱼码率档标识（kbps）；无后缀 = 最高档（原画）。

### 9.2 改动内容

1. **`config.ini`**（宿主机 `/opt/1panel/docker/compose/config/config.ini`，挂载到容器 `/app/config/`）`[Cookie]` 段写入 `斗鱼cookie`。
   - **必须用 `configparser.RawConfigParser` 写入**（程序 `main.py:1755` 即用它读取，默认 `ConfigParser` 会因 cookie 里的 `%` 报 "invalid interpolation syntax"）。
   - 备份：`config.ini.bak.20260819161326`
2. **`spider.py`**（宿主机 `/opt/1panel/docker/compose/code_overlay/src/spider.py`，overlay 挂载）两处：
   - `get_token_js()` 增加 `cookies` 参数，请求头带 `Cookie`
   - `get_douyu_stream_data()`：有 cookie 时提取 `dy_did`/`acf_did`（正则 `(?:^|;\s*)(?:dy_did|acf_did)=([^;]+)`）作为签名 `did`，并透传 `Cookie` 头；**无 cookie 时保持匿名行为不变**（向后兼容）
   - 备份：`spider.py.bak.20260819161326`

### 9.3 ⚠️ 关键：改 overlay 代码后必须重启容器

`code_overlay/src/spider.py` 是**单文件挂载**，只覆盖磁盘文件，**不会热更新运行中的进程**。`python main.py` 在进程启动时已把 `spider` 模块加载进内存，改文件后不重启，录制仍走旧代码。

- 本次踩坑：patch 完用 `docker exec python3` 验证取流已是 1440p，但**实际录制仍是 540p**——因为主进程还是旧的。`docker compose restart live` 后才生效。
- **教训：以后改 overlay 后必须 `cd /opt/1panel/docker/compose && docker compose -f douyin-live-recorder.yaml restart live`**（restart 保留挂载，无需重建；注意 compose 有 obsolete `version` 告警，可忽略）。

### 9.4 验证（命令即证据）

```bash
# 1. 取流接口返回最高档（docker exec 新进程验证）
docker exec live ffprobe ...   # rate=0 -> 2560x1440/60fps/8.8Mbps

# 2. 重启容器后实际录制产物
ffprobe 原画__轰轰仔_2026-08-19_16-22-58.mp4
# -> width=2560 height=1440 r_frame_rate=60/1 bit_rate=8823517   ✅ 原画生效
```

### 9.5 注意事项

- cookie 有效期约至 2026-08-25（JWT `exp=1787670279`），过期后更新 `斗鱼cookie`；**过期或留空时程序回退匿名**（仍可录，但只有 540p）
- 若斗鱼接口再改版，排查顺序：确认 cookie 未过期 → 比对 `getEncryption`/`getH5PlayV1` 签名 → 检查是否又被降级（看流文件名 `_900` 即嫌疑）
- 恢复原始代码：删除 overlay 挂载并重启，见第 8 节

## 10. douyu-live 专用容器 + cookie 续签（2026-08-19）

### 10.1 douyu-live 容器（专门录制斗鱼）

独立于 `live` 容器的第二个录制实例，专注斗鱼房间，配置/数据完全隔离：

| 项 | 值 |
|---|---|
| 容器名 | `douyu-live` |
| compose | `/opt/1panel/docker/compose/douyu-live/douyu-live.yaml` |
| 数据目录 | `/opt/1panel/docker/compose/douyu-live/{config,logs,downloads,backup_config,code_overlay}` |
| spider.py | 同修复版（md5 `ba102ac`），overlay 挂载 |
| config.ini | 只含斗鱼cookie，其余平台 cookie 清空，推送关闭 |

常用命令：
```bash
ssh yoga13 'cd /opt/1panel/docker/compose/douyu-live && docker compose -f douyu-live.yaml up -d'   # 启动
ssh yoga13 'docker logs --tail 20 douyu-live'
# 开启/关闭某房间录制：直接改 douyu-live/config/URL_config.ini 的行首 #（toggle_room.sh 只作用于 live 容器的路径！）
```

> ⚠️ **`/usr/local/bin/toggle_room.sh` 硬编码 `FILE=/opt/1panel/docker/compose/config/URL_config.ini`（live 容器）**，不会作用于 douyu-live。要给 douyu-live 开关房间，直接编辑 `/opt/1panel/docker/compose/douyu-live/config/URL_config.ini`（改行首 `#`），或复制脚本改路径。

### 10.2 cookie 续签方案（半自动：到期提醒 + 一键更新）

斗鱼 JWT（`acf_jwt_token`）约 7 天过期且**无公开刷新接口**（必须浏览器重新登录拿新 cookie），故采用半自动：

| 脚本 | 位置 | 作用 |
|---|---|---|
| 检查 | `/usr/local/bin/check_dy_cookie.sh` | 每日 cron 解析 JWT `exp`，剩 ≤2 天写告警到 `/var/log/dy_cookie_renew.log` |
| 更新 | `/usr/local/bin/update_dy_cookie.sh` | 交互粘贴新 cookie → 写 config.ini → 重启容器 → 自动验证取流是否解锁原画 |

cron 已装：`0 9 * * * /usr/local/bin/check_dy_cookie.sh`

手动换 cookie：
```bash
ssh yoga13 '/usr/local/bin/update_dy_cookie.sh'
# 1) 浏览器打开 douyu.com（保持登录），F12→Application→Cookies 复制全部 cookie
# 2) 粘贴→回车，脚本自动写入+重启+验证
```

> cookie 更新后**必须重启容器**（main.py 只在启动时读一次 cookie，见 9.3）；更新脚本已内置 restart + 取流验证（返回 `_900` 即失败）。

---

## 11. 部署案例：cone-142 复刻 douyu-live（2026-08-19）

> 将 §10 的 douyu-live 容器方案在 **cone-142** 服务器上复刻部署。结构/思路与 yoga13 完全一致，**仅路径与数据目录不同**（cone-142 无独立 downloads，直接挂 clouddrive 同步根）。

### 11.1 环境差异（cone-142 vs yoga13）

| 项 | yoga13（§10） | cone-142（本案例） |
|---|---|---|
| 录制主容器 | `live` | `douyin-live`（live-reco compose） |
| 配置目录 | `/opt/1panel/docker/compose/config/` | `/opt/1panel/docker/compose/live-reco/live/config/` |
| douyu-live compose | `/opt/1panel/docker/compose/douyu-live/douyu-live.yaml` | 同路径 |
| spider.py overlay | 修复版 md5 `ba102ac` | 修复版 md5 ~~`5c478a6`~~ **`8503dd3`**（2026-08-19 补 §9.2 cookie 补丁后；同 workspace `base-yoga13s/docs/spider.py.patched`） |
| 下载挂载 | `/opt/1panel/docker/compose/douyu-live/downloads` | **clouddrive 同步根** `/opt/1panel/docker/compose/live-reco/clouddrive2/142.171.203.142/clouddrive:/app/downloads:rslave`（与 douyin-live 共用，随 123 云盘同步） |
| config.ini | 只含斗鱼cookie，其余清空 | **全平台 cookie 均空**（含斗鱼，用匿名 540p）；推送关闭；保存路径 `/app/downloads/斗鱼直播` |
| 镜像 | 有斗鱼专用镜像 | `ihmily/douyin-live-recorder:v4.0.7`（本地已有，含旧版失效 spider） |

> ⚠️ cone-142 的镜像内 spider.py 是**旧版**（md5 `f6a180e…`，含失效的 `vdwdae325w_64we` 正则，无 getEncryption/getH5PlayV1）——因此 **overlay 单文件挂载是必须的**，否则斗鱼取流直接 `'NoneType' object has no attribute 'group'`（§2.1 症状）。

### 11.2 部署结构

```
/opt/1panel/docker/compose/douyu-live/
├── douyu-live.yaml                      # compose（见下）
├── config/
│   ├── config.ini                       # Cookie全空/推送关/保存路径=斗鱼直播
│   └── URL_config.ini                   # 默认仅注释示例行
├── logs/                                # PlayURL.log / streamget.log
├── backup_config/                       # 启动时自动备份
└── code_overlay/src/spider.py           # 修复版 md5 ~~5c478a6~~ 8503dd3（含§9.2 cookie补丁）, :ro 挂载
```

`douyu-live.yaml`（与 §10 相比：无独立 downloads、overlay 挂 `:ro`、无 compose `version` 键避免告警）：

```yaml
services:
  douyu-live:
    image: ihmily/douyin-live-recorder:v4.0.7
    container_name: douyu-live
    environment:
      - TERM=xterm-256color
    tty: true
    stdin_open: true
    volumes:
      - ./config:/app/config
      - ./logs:/app/logs
      - ./backup_config:/app/backup_config
      - ./code_overlay/src/spider.py:/app/src/spider.py:ro
      - /opt/1panel/docker/compose/live-reco/clouddrive2/142.171.203.142/clouddrive:/app/downloads:rslave
    restart: unless-stopped
    network_mode: host
```

### 11.3 关键操作步骤（复现用）

```bash
# 1. 目录 + overlay（spider.py 来自 workspace base-yoga13s/docs/spider.py.patched）
ssh cone-142 'mkdir -p /opt/1panel/docker/compose/douyu-live/{config,logs,backup_config,code_overlay/src}'
scp base-yoga13s/docs/spider.py.patched cone-142:/opt/1panel/docker/compose/douyu-live/code_overlay/src/spider.py

# 2. 基准 config 从镜像初始化，再改造（Cookie全空/推送关/保存路径）
docker run --rm -v /opt/1panel/docker/compose/douyu-live/config:/tmp/c --entrypoint sh \
  ihmily/douyin-live-recorder:v4.0.7 -c 'cp /app/config/config.ini /app/config/URL_config.ini /tmp/c/'
#   用 python configparser 清 Cookie 段、关推送（开播推送=否/渠道空）、
#   设 录制设置->直播保存路径(不填则默认)=/app/downloads/斗鱼直播

# 3. 写 douyu-live.yaml（见 11.2），启动
ssh cone-142 'cd /opt/1panel/docker/compose/douyu-live && docker compose -f douyu-live.yaml up -d'
```

### 11.4 验证（命令即证据）

```bash
# 1. overlay 生效（md5 一致）
docker exec douyu-live md5sum /app/src/spider.py          # ~~5c478a6~~ 8503dd3 (含§9.2 cookie补丁)
md5sum /opt/1panel/docker/compose/douyu-live/code_overlay/src/spider.py

# 2. 取流全链路（6925114=轰轰仔，§9.1 验证房间）
docker exec douyu-live sh -c "cd /app && python3 -c \"
import asyncio, json
from src import spider
async def m():
    r = await spider.get_douyu_stream_data('6925114','0',None,None)
    print(r.get('error'), r.get('msg'), str(r.get('data'))[:200])
asyncio.run(m())
\""
# → 0 ok {'room_id': 6925114, ..., 'rtmp_live': '6925114rIDrEEuKo_900.flv?wsAuth=...'}

# 3. 实际拉流探测（匿名 -> _900 档 960x540）
docker exec douyu-live ffprobe -v error -show_entries stream=codec_name,width,height,bit_rate \
  -of default=noprint_wrappers=1 'https://ws3.douyucdn.cn/live/6925114rIDrEEuKo_900.flv?wsAuth=...'
# → h264 960x540 / aac（返回码 0）

# 4. 日志无错误
docker logs douyu-live 2>&1 | grep -c ERROR                # → 0
```

### 11.5 当前状态与后续

- 容器 `douyu-live` Up、restart unless-stopped；`douyin-live` 不受影响（双容器并存）
- ~~**当前为匿名 540p 录制**（config 斗鱼cookie 空）~~ **已带斗鱼cookie 录制原画**（2026-08-19：config.ini 写入 cookie 且 spider.py 补上 §9.2 cookie补丁后，取流实测 2560×1440/8.4Mbps，流名无 `_900` 后缀）。cookie 过期后**必须重启容器**（main.py 启动时读一次 cookie）；更新 cookie 用 `/usr/local/bin/update_dy_cookie.sh`
- **spider.py md5 变更记录（2026-08-19）**：`5c478a6`（仅取流修复，含旧"不要透传cookie"注释）→ `8503dd3`（补 §9.2 cookie补丁：get_token_js 加 cookies 参数 + get_douyu_stream_data 提取 dy_did/acf_did 并透传 Cookie 头）。工作区 `base-yoga13s/docs/spider.py.patched` 已同步为 `8503dd3`
- 产物落在 clouddrive 根 `斗鱼直播/`（首个录制自动创建目录），随 clouddrive2 同步到 123 云盘
- 开关房间：直接编辑 `douyu-live/config/URL_config.ini` 行首 `#`（cone-142 的 toggle_room.sh 同样只作用于 douyin-live 路径，见 B 节备注）