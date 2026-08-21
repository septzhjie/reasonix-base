# DouyinLiveRecorder —— 服务器维护记录

## 项目概览

- **软件**：ihmily/DouyinLiveRecorder v4.0.7（已停止维护，GitHub: https://github.com/ihmily/DouyinLiveRecorder）
- **用途**：多平台直播录制（抖音/斗鱼/虎牙/YY/B站 等）
- **部署位置**：服务器 `yoga13`（本机通过 `ssh yoga13` 访问，root 用户）
- **编排**：1Panel 管理的 docker compose，compose 文件在 `/opt/1panel/docker/compose/douyin-live-recorder.yaml`
- **容器名**：`live`，镜像 `ihmily/douyin-live-recorder:latest`
- **数据目录**（宿主机 `/opt/1panel/docker/compose/` 下，均已挂载进容器 `/app/`）：
  - `config/` → `/app/config`（`config.ini` 录制配置 + `URL_config.ini` 直播间地址）
  - `logs/` → `/app/logs`
  - `backup_config/` → `/app/backup_config`
  - `downloads/` → `/app/downloads`（录制产物）

## 网络拓扑（重要背景）

```
yoga13（宿主机，Ubuntu 22.04，NetworkManager）
├── wlp1s0  WiFi 192.168.5.4/24    ← 唯一能走 250 代理的接口
├── enx00e04c680139 USB有线 → br0（桥）192.168.5.3/24（内含 vnet3）
└── KVM 虚拟机 istoreos（旁路由 192.168.5.250，fake-ip 代理）← 跑在 yoga13 上！
```

- **192.168.5.250 是 yoga13 上 KVM 跑的 iStoreOS 虚拟机**（旁路由 + fake-ip 代理），部署详见 `docs/istoreos-kvm-deploy.md`
- 250 网关**只代理 WiFi(wlp1s0) 口的流量**；有线(br0) 走 250 代理流量会被丢弃
- **192.168.5.1（主路由）DNS 污染**：会把 `www.google.com` 解析成 `127.0.0.1`，只要 DNS 走 br0 链路 Google 必不通
- 完整网络笔记：`docs/wlp1s0-static-networking.md`

## wlp1s0 网络切换脚本（2026-08-21）

`scripts/wlp1s0-net.sh`（set / restore / check 三模式，幂等）：

```bash
./scripts/wlp1s0-net.sh set      # 静态：IP=当前地址、网关/DNS=192.168.5.250、DNS/路由双优先
./scripts/wlp1s0-net.sh restore  # 恢复 DHCP（清空全部静态项）
./scripts/wlp1s0-net.sh check    # 只读检查
```

两个关键参数（缺一不可）：
- `ipv4.dns-priority -100` → 防 192.168.5.1 DNS 污染（否则 google 解析成 127.0.0.1）
- `ipv4.route-metric 100` → 默认路由优先走 wlp1s0/250（NM 对 Wi-Fi 有 20000 基线叠加，激活瞬间显示 20100 是过渡态，勿误判，脚本已内置 sleep 5）

注意：恢复 DHCP 后 Google 不通**属预期**（无 250 DNS/代理）；要 Google 必须处于 set 状态。

## 已做的修复（2026-08-18）

斗鱼直播取流功能已失效并被修复，详见 **`docs/douyu-stream-fix.md`**。核心结论：

1. 斗鱼改版（Next.js + 新 web-encrypt 签名），旧版 JS 指纹 `vdwdae325w_64we`/`ub98484234` 已移除，旧代码抛 `'NoneType' object has no attribute 'group'`，无法取流
2. 逆向新版签名算法后重写 `spider.py` 的 `get_token_js` + `get_douyu_stream_data`
3. **持久化方式**：宿主机 `/opt/1panel/docker/compose/code_overlay/src/spider.py` 通过 compose 单文件挂载覆盖容器 `/app/src/spider.py`，1Panel 重建容器不丢失
4. 取流接口**不能传 cookie**（旧/过期 cookie 触发"鉴权失败"）

## 日常维护命令

```bash
# 看日志
ssh yoga13 'docker logs --tail 100 live'

# 错误统计
ssh yoga13 'docker logs live | grep ERROR | tail -20'

# 确认录制产物
ssh yoga13 'ls -laR /opt/1panel/docker/compose/downloads/'

# 重启容器（compose 变更后）
ssh yoga13 'cd /opt/1panel/docker/compose && docker compose -f douyin-live-recorder.yaml up -d --force-recreate'
```

## 部署脚本（推荐）

本地工作区有 `scripts/deploy-fix.sh`，一键部署斗鱼修复到服务器（幂等、带校验）：

```bash
./scripts/deploy-fix.sh --check   # 只检查现状：md5 对账 / 挂载 / 容器状态
./scripts/deploy-fix.sh           # 部署：上传→挂载确认→重建容器→md5 验证→日志查错
```

- 修复文件来源：本地 `docs/spider.py.patched` → 服务器 `/opt/1panel/docker/compose/code_overlay/src/spider.py`
- md5 一致时跳过上传；compose 已有挂载行时跳过修改
- 注意：完整部署会重建容器，中断当前录制片段（脚本会等待 60s 查日志验证）

## 工作区其他脚本/文档

| 文件 | 用途 |
|---|---|
| `scripts/wlp1s0-net.sh` | wlp1s0 静态(250代理)/恢复 DHCP 切换（详见上方章节） |
| `scripts/deploy-fix.sh` | 部署斗鱼取流修复（详见上方章节） |
| `scripts/toggle_room.sh` | 定时录制开关（服务器 `/usr/local/bin/toggle_room.sh` 的本地副本） |
| `scripts/send-ali-mail.sh` | 阿里企业邮箱 SMTP 发信（`docs/ali-email-smtp.md`） |
| `scripts/douyu-live/check_dy_cookie.sh` | 斗鱼 cookie 有效期检查（≤2天发提醒邮件） |
| `scripts/douyu-live/update_dy_cookie.sh` | 手动更新斗鱼 cookie |
| `docs/istoreos-kvm-deploy.md` | KVM 部署 iStoreOS 旁路由 192.168.5.250（已部署） |
| `docs/wlp1s0-static-networking.md` | 双网卡/代理网关/DNS 污染完整笔记 |

## 配置要点

- 直播间列表：`/opt/1panel/docker/compose/config/URL_config.ini`（`[room]` 段，每行一个 URL）
- 录制设置：`/opt/1panel/docker/compose/config/config.ini`（`[录制设置]` 段；注意 `%` 会被 configparser 插值，代码用 RawConfigParser 读取）
- 当前监控：斗鱼房间 `https://www.douyu.com/5551871`（主播 Minana呀）

## 定时录制（cron，可选）

需要"某时间段内录制某地址"：本项目无内置定时，用 cron + 注释切换实现（详见 `docs/cron-scheduled-recording.md`）：

- 脚本 `/usr/local/bin/toggle_room.sh`（on=去掉`#`开录 / off=加`#`停录 / status=查状态）
- crontab 模板 `/root/recorder_cron.template`（已安装，示例任务注释状态，改时间后启用）
- 操作日志 `/var/log/recorder_cron.log`

## 维护风险

- 斗鱼签名算法可能再次变更；若日志重现 `鉴权失败`/`时间戳错误`/`NoneType`，按 `docs/douyu-stream-fix.md` 的"重新验证"章节排查
- 1Panel 面板侧改动 compose 可能与此文件冲突，改动前先备份
- 停止维护的软件，平台接口变更后大概率需要再次手修
- **网络坑**：192.168.5.1 网关把 google 解析成 127.0.0.1（DNS 污染）；250 只代理 WiFi 口；NM 对 Wi-Fi 路由有 20000 基线（metric 过渡态）。排障先看 `resolvectl query www.google.com` 的 `-- link:`（应为 wlp1s0）与 `ip route show default`（应 via 192.168.5.250 dev wlp1s0）；详情见 `docs/wlp1s0-static-networking.md`
- **iStoreOS（250）是 yoga13 的 KVM 虚拟机**：重启/误关虚拟机 = 全家代理/wifi 静态网关失效；虚拟机关闭期间 wlp1s0 静态网关不可用，需 `restore` 回 DHCP 或启动虚拟机