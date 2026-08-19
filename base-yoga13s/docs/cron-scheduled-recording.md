# 定时录制（cron）操作手册

> 需求：在某个时间段内录制某个直播间地址

## 两套方案概览

**当前存在两套独立部署，按服务器区分：**

| | 方案 A：yoga13 | 方案 B：cone-142 |
|---|---|---|
| 容器 | `live` | `douyin-live` |
| 配置路径 | `/opt/1panel/docker/compose/config/URL_config.ini` | `/opt/1panel/docker/compose/live-reco/live/config/URL_config.ini` |
| 任务来源 | root crontab（唯一） | **1Panel 计划任务 + root crontab 并存** |
| 切换脚本 | `/usr/local/bin/toggle_room.sh` | `/usr/local/bin/toggle_room.sh`（已适配路径） |
| 定时模板 | `/root/recorder_cron.template` | `/root/recorder_cron.template` |
| 操作日志 | `/var/log/recorder_cron.log` | `/var/log/recorder_cron.log` |
| URL 行格式 | `URL,画质: 名称` | `URL,主播: 名称` |

> 下文"实现原理 ~ 注意事项"为**方案 A（yoga13）**的说明；**方案 B（cone-142）**见文末专节。

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

---

# 方案 B：cone-142（DouyinLiveRecorder，`douyin-live` 容器）

> 适用服务器：cone-142（root）｜ 容器：`douyin-live`（live-reco compose 项目）
> 部署日期：2026-08-19 ｜ 依据：`/root/live-reco-schedule-20260819.txt`（地址↔任务对照表，由 1Panel 计划任务生成）

## B.0 与方案 A 的差异

- 配置目录不同：cone-142 为 `/opt/1panel/docker/compose/live-reco/live/config/`（bind 挂载到容器 `/app/config`，改宿主机即生效）
- URL 行格式：`URL,主播: 名称`（无 `[room]` 段头，行首 `#` = 禁用同方案 A）
- **任务双轨并存**：cone-142 同时有 **1Panel 计划任务**（`/opt/1panel/db/agent.db` → `cronjobs` 表，8 个 Enable）和 **root crontab**（12 条，本方案本次部署）。两者都只对 `URL_config.ini` 加/去 `#`，**幂等不冲突**；但改时段需两处同步修改。

## B.1 组件

| 项目 | 位置 |
|---|---|
| 切换脚本 | `/usr/local/bin/toggle_room.sh`（从 workspace `base-yoga13s/toggle_room.sh` 拷贝，已适配 cone-142 路径） |
| 定时模板 | `/root/recorder_cron.template`（root crontab 已安装模板，12 条任务行） |
| 操作日志 | `/var/log/recorder_cron.log` |

脚本用法同方案 A：`toggle_room.sh on|off [URL关键字]`、`toggle_room.sh status`（status 无关键字时列出全部启用行）。URL 关键字可用 `963797965154`、`huya.com/145920` 等唯一片段。

## B.2 当前排程（2026-08-19，与 1Panel 计划任务一致）

`URL_config.ini` 共 11 行：行1-7 默认 `#` 禁（由任务按点开关），行8-11 固定启用。

| 行 | 地址 | 主播 | cron（on/off） |
|---|---|---|---|
| 1 | `live.douyin.com/963797965154` | 周七er(声控助眠) | 08:30开 / 10:30关，12:30开 / 14:30关（每日两场） |
| 2 | `www.huya.com/145920` | 若若若呀丶 | 22:00开 / 01:00关 |
| 3 | `live.douyin.com/58826209230` | 白榆(轻语助眠) | 22:00开 / 01:00关 |
| 4 | `live.bilibili.com/1702260284` | 千早澪Lynn | 22:00开 / 01:00关 |
| 5 | `live.douyin.com/196605938031` | 小小酸奶昔_(声控助眠) | 03:00开 / 06:00关 |
| 6 | `live.douyin.com/150342350298` | 好好好姐姐 | 固定关闭 |
| 7 | `www.huya.com/29029` | HR-梗梗 | 固定关闭 |
| 8-11 | — | 抱抱er/樱桃小栗子×2/扎双马尾的丧尸 | 固定启用 |

```cron
# 行2-4：22:00 开录，次日 01:00 停录
0 22 * * * /usr/local/bin/toggle_room.sh on  https://www.huya.com/145920
0 22 * * * /usr/local/bin/toggle_room.sh on  https://live.douyin.com/58826209230
0 22 * * * /usr/local/bin/toggle_room.sh on  https://live.bilibili.com/1702260284
0 1  * * * /usr/local/bin/toggle_room.sh off https://www.huya.com/145920
0 1  * * * /usr/local/bin/toggle_room.sh off https://live.douyin.com/58826209230
0 1  * * * /usr/local/bin/toggle_room.sh off https://live.bilibili.com/1702260284
# 行5：03:00 开录，06:00 停录
0 3 * * * /usr/local/bin/toggle_room.sh on  https://live.douyin.com/196605938031
0 6 * * * /usr/local/bin/toggle_room.sh off https://live.douyin.com/196605938031
# 行1：08:30/10:30 + 12:30/14:30 两场
30 8  * * * /usr/local/bin/toggle_room.sh on  https://live.douyin.com/963797965154
30 10 * * * /usr/local/bin/toggle_room.sh off https://live.douyin.com/963797965154
30 12 * * * /usr/local/bin/toggle_room.sh on  https://live.douyin.com/963797965154
30 14 * * * /usr/local/bin/toggle_room.sh off https://live.douyin.com/963797965154
```

## B.3 1Panel 计划任务（并存，勿重复添加）

- 任务数据存于 `/opt/1panel/db/agent.db` 的 `cronjobs` 表（16 条；8 Enable / 8 Disable）
- 8 个启用任务与上方 cron 排程一一对应（`live-PM11-AM2-on/off`、`live-AM3-AM7-on/off`、`live-AM8-AM11-on/off`、`周七-on/off`）
- 已停用的 8 个（`AM-3-off`、`PM-11-on` 等）为历史任务，勿启用；其中 `live-PM8-PM10-*`、`live-PM11-AM3-*` 的行号（13/17）已超出当前文件
- **修改排程时：crontab 与 1Panel 两处都要改，保持一致**

## B.4 日常操作

```bash
# 查看当前 URL 启用状态（全部行）
ssh cone-142 '/usr/local/bin/toggle_room.sh status'
# 查看某 URL 状态 / 手动开关
ssh cone-142 '/usr/local/bin/toggle_room.sh status https://live.douyin.com/963797965154'
ssh cone-142 '/usr/local/bin/toggle_room.sh on  https://live.douyin.com/963797965154'
ssh cone-142 '/usr/local/bin/toggle_room.sh off https://live.douyin.com/963797965154'
# 查看定时执行记录
ssh cone-142 'tail -10 /var/log/recorder_cron.log'
# 查看/编辑定时
ssh cone-142 'crontab -l'    # 或 crontab -e
# 查容器录制行为
ssh cone-142 'docker logs --tail 20 douyin-live | grep -E "正在录制|传入地址"'
```

## B.5 备注

- 部署验证（2026-08-19）：crontab 语法校验 12/12 OK、cron 服务 active；对行5 做 `on→off` 实测幂等且文件还原正确；当前 11 行状态与 1Panel 14:30 `周七-off` 结果一致
- 切换脚本依赖 python3，cone-142 已具备；脚本 `chmod +x`
- 若需彻底停用 cone-142 的 cron 定时：`ssh cone-142 'crontab -r'`（1Panel 任务不受影响，仍需在面板单独停用）