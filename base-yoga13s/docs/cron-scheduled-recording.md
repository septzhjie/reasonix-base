# 定时录制（cron）操作手册

> 适用：DouyinLiveRecorder 容器 `live`（服务器 `yoga13`，root）
> 需求：在某个时间段内录制某个直播间地址

## 实现原理

**本项目没有内置"按时间段录制"功能**，录制只随开播/关播走。实现方式是：

1. `URL_config.ini` 每行格式：`直播间URL,画质: 名称`
2. **行首带 `#` = 禁用**：main.py 每轮循环（120 秒）重新读文件时，`#` 行被收集到 `url_comments`，不进入监测列表 → 不录制
3. 行首无 `#` = 启用：正常监测，开播即录
4. 用 root 的 cron 定时调用 `/usr/local/bin/toggle_room.sh` 给目标行的行首加/去 `#`，实现"到点开录 / 到点停录"

**行为确认（2026-08-18 实测）**：
- `on`（去掉 `#`）：最迟 120 秒内恢复监测并开录
- `off`（加上 `#`）：能停止正在录的线程（日志转为"没有正在录制的直播"），结束也较准时

## 已部署的组件

| 项目 | 位置 |
|---|---|
| 切换脚本 | `/usr/local/bin/toggle_room.sh`（本地工作区也有 `toggle_room.sh` 副本） |
| crontab 模板 | `/root/recorder_cron.template`（root crontab 已安装此模板，示例任务为注释状态） |
| 操作日志 | `/var/log/recorder_cron.log`（每次 on/off 落一行时间戳） |

## 日常操作

### 1. 查看当前是否在录 / URL 状态

```bash
ssh yoga13 '/usr/local/bin/toggle_room.sh status'
# → "已启用（正常监测）" 或 "已禁用（# 注释，不监测）"

ssh yoga13 'docker logs --tail 20 live | grep -E "正在录制|传入地址"'
```

### 2. 手动开启 / 停止录制（不依赖定时）

```bash
ssh yoga13 '/usr/local/bin/toggle_room.sh on  https://www.douyu.com/5551871'   # 开录
ssh yoga13 '/usr/local/bin/toggle_room.sh off https://www.douyu.com/5551871'   # 停录
# URL 关键字可省略，默认就是 https://www.douyu.com/5551871
```

### 3. 设置/修改"每天固定时间段"（核心）

编辑 crontab（`crontab -e`），把示例行的 `#` 去掉并改成你的时间。

**当前已启用（2026-08-19 配置）：**

```
# 每晚 22:00 开录，次日凌晨 01:00 停录
0 22 * * * /usr/local/bin/toggle_room.sh on  https://www.douyu.com/5551871
0 1  * * * /usr/local/bin/toggle_room.sh off https://www.douyu.com/5551871
```

- **开始时间**：`0 22 * * *`（每晚 22:00）
- **停止时间**：`0 1 * * *`（次日凌晨 01:00；cron 跨天自然生效）
- 改完保存即生效；可 `crontab -l` 复核
- 其它时段示例（未启用，改时间后去掉 `#`）：

```
# 每天 20:00-22:00 示例
# 0 20 * * * /usr/local/bin/toggle_room.sh on  https://www.douyu.com/5551871
# 0 22 * * * /usr/local/bin/toggle_room.sh off https://www.douyu.com/5551871
```

### 4. 每周特定日子（参考）

```
# 每周一到周五 20:00-22:00
0 20 * * 1-5 /usr/local/bin/toggle_room.sh on  https://www.douyu.com/5551871
0 22 * * 1-5 /usr/local/bin/toggle_room.sh off https://www.douyu.com/5551871
```

cron 星期语法：`0=周日, 1-5=周一~周五, 6=周六`

### 5. 验证定时生效

```bash
# 查切换脚本执行记录（每次 on/off 都有时间戳）
ssh yoga13 'tail -10 /var/log/recorder_cron.log'

# 查容器录制行为
ssh yoga13 'docker logs --since 5m live | grep -E "传入地址|正在录制|没有正在" | tail -5'

# 查产物（确认有/没有新文件）
ssh yoga13 'ls -laR /opt/1panel/docker/compose/downloads/'
```

### 6. 彻底停用定时录制

```bash
ssh yoga13 'crontab -r'    # 删除全部 crontab（只影响本服务器 root 的定时任务）
# 或只注释掉对应行后 crontab -e 保存
```

### 7. 换一个地址录制

```bash
# 1) 在 URL_config.ini 增加目标地址行（容器内 /app/config/URL_config.ini 即宿主机 /opt/1panel/docker/compose/config/URL_config.ini）
ssh yoga13 'echo "https://www.douyu.com/123456,原画: 房间名" >> /opt/1panel/docker/compose/config/URL_config.ini'
# 2) 把 cron 里的 URL 关键字换成新地址
ssh yoga13 'crontab -e'
```

## 注意事项

- **容器重启后**：URL 行是 `#` 状态则不会监测；定时会把该行切回 on，所以定时开启后一切正常
- **off 不停立即停录**？实测会停（线程被清理）；若个别平台有延迟，最多 2 分钟
- 修改 `URL_config.ini` 请勿破坏 `[room]` 段头和其它行；main.py 偶尔会去重/重写该文件，但格式保持不变
- 所有命令在 `yoga13` 上用 root 执行；脚本已 `chmod +x`