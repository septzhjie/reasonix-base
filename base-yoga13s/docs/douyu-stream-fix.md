# 斗鱼直播取流修复记录（2026-08-18）

> 适用范围：DouyinLiveRecorder v4.0.7（ihmily/douyin-live-recorder:latest），容器 `live`，由 1Panel + docker compose 部署在服务器 `yoga13`。

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