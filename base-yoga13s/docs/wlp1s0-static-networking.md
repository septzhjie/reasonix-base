# yoga13 网络配置笔记 —— wlp1s0 静态代理网关 / 双网卡路由

> 适用机器：`yoga13`（Ubuntu 22.04.5，NetworkManager 1.36.6，root）
> 相关脚本：`scripts/wlp1s0-net.sh`（set / restore / check 三模式）

## 1. 网络拓扑与接口现状

```
                    ┌─────────────────────────────────────────────┐
                    │                 yoga13                      │
                    │                                              │
  WiFi  ────────────┤ wlp1s0          192.168.5.4/24  (静态可选)  │
  无线              │    └─ 连接名: ZTE-UDzGd3                     │
                    │                                              │
  有线  enx00e04c6… │——> br0（桥）    192.168.5.3/24  (DHCP)      │
        (USB网卡)   │    └─ 成员: enx00e04c680139, vnet3(VM)      │
                    │                                              │
                    │ 虚拟: docker0(172.17) br-*  virbr0(192.168.122) │
                    └─────────────────────────────────────────────┘

网关：
  192.168.5.1     —— 普通路由器（DHCP/DNS 分发；会把 google.com 解析成 127.0.0.1，DNS 污染源）
  192.168.5.250   —— 「iStoreOS」网关，带代理（fake-ip 模式），只代理 WiFi 口的流量
```

### 物理网卡对照

| 网卡 | 硬件 | 自身 IP | 说明 |
|---|---|---|---|
| `wlp1s0` | PCI 无线网卡 | 192.168.5.4/24 | 真正能走 250 代理的接口 |
| `enx00e04c680139` | USB 有线网卡 | 无（桥成员） | 挂在 `br0` 上，br0 持有 192.168.5.3 |

## 2. 关键坑（务必理解，否则必然踩雷）

### 坑 A：192.168.5.1 网关 DNS 污染 Google

`192.168.5.1` 这个网关把 `www.google.com` 解析成 **`127.0.0.1`**：

```
$ dig +short A www.google.com @192.168.5.1
127.0.0.1      ← 污染
```

因此**只要系统 DNS 走了 br0 链路（192.168.5.1），Google 必不通**（curl 连 127.0.0.1:443）。

### 坑 B：192.168.5.250 只代理 WiFi 口流量

250 网关（iStoreOS + fake-ip 代理）**只处理从 wlp1s0（WiFi）进入的流量**：

- wlp1s0 走 250 → Google HTTP 200 ✅（fake-ip `198.18.0.146`）
- br0（有线）走 250 → Google 立即失败（`total=0.001s`，SYN 无响应）❌，但 baidu 透传正常（HTTP 200）

所以**有线网卡不能靠 250 网关代理 Google**，代理必须走 WiFi 口。

### 坑 C：NM 路由 metric 过渡态 / Wi-Fi 基线叠加

`nmcli connection up` 激活瞬间，wlp1s0 静态路由 metric 会短暂显示 **20100**（Wi-Fi 设备 20000 基线 + 配置值），约几秒后收敛为配置值 100。**刚 up 完就测 curl 会得到过渡态误报**，需等待数秒。

## 3. 目标状态（脚本 `set` 所做）

```
ipv4.method:        manual
ipv4.gateway:       192.168.5.250
ipv4.addresses:     192.168.5.4/24   （沿用 DHCP 拿到的地址）
ipv4.dns:           192.168.5.250
ipv4.dns-priority:  -100             ← 关键：DNS 优先用 250，防 br0 污染
ipv4.route-metric:  100              ← 关键：默认路由优先走 WiFi
```

生效后路由表：

```
default via 192.168.5.250 dev wlp1s0 proto static metric 100   ← 优先（WiFi 代理）
default via 192.168.5.1   dev br0      proto dhcp   metric 425  ← 后备（有线）
```

### 为什么需要 `dns-priority -100`？

NM 默认所有连接 `dns-priority=0`，systemd-resolved 按**路由 metric 选 DNS 上游**。
若 br0 路由基数（425）低而 wlp1s0 是 20100 过渡态，DNS 全走 br0 → 触发坑 A 污染。
把 wlp1s0 的 dns-priority 设为负数（如 -100）后，resolved **优先用 250 解析**，无论路由 metric 如何：

```
$ resolvectl query www.google.com
www.google.com: 198.18.0.146  -- link: wlp1s0   ← 正确 fake-ip
```

## 4. 快速操作

```bash
# 设为静态（沿用当前 IP，网关/DNS=192.168.5.250，优先 DNS 与路由）
./scripts/wlp1s0-net.sh set

# 恢复 DHCP（清空全部静态项，回到出厂式网络）
./scripts/wlp1s0-net.sh restore

# 只读查看当前状态（不修改）
./scripts/wlp1s0-net.sh check
```

脚本可加环境变量覆盖默认：`SSH_TARGET` `IFACE` `CONN` `GATEWAY` `DNS` `RT_METRIC` `DNS_PRIORITY`。

## 5. 验证与排障

### 常用检查命令

```bash
# 1. 解析是否被污染（应显示 fake-ip 198.18.x.x，link 应为 wlp1s0）
resolvectl query www.google.com

# 2. 若显示 127.0.0.1 -- link: br0  → DNS 被 192.168.5.1 污染
#    修法：确认 wlp1s0 的 ipv4.dns-priority 为负数（set 脚本已含）

# 3. 默认路由是否走 250
ip route show default

# 4. fake-ip 流量途经确认
ip route get 198.18.0.146

# 5. 连通性
curl -4 -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://www.google.com
```

### 排障决策树

| 症状 | 原因 | 处理 |
|---|---|---|
| google 解析成 127.0.0.1 | DNS 走了 192.168.5.1 | `nmcli connection modify ZTE-UDzGd3 ipv4.dns-priority -100 && nmcli connection up ZTE-UDzGd3` |
| google 立即失败（0.001s）| 流量走 br0→250 或有线口 | 确认默认路由 `via 192.168.5.250 dev wlp1s0`（`ip route`）|
| up 后 curl 超时几秒后正常 | NM 路由 metric 过渡态 20100 | 等待数秒再测（脚本已内置 sleep 5）|
| 有线口走 250 不通 google | 250 只代理 WiFi 口 | 用 wlp1s0；不要指望有线口代理 |

### 恢复 DHCP 后 Google 不通？（属预期）

`restore` 后 DNS 回到 `59.49.49.49 / 223.6.6.6 / 192.168.5.1`，192.168.5.1 仍会污染 google → 恢复 DHCP 状态下 **Google 不通是预期行为**（无 250 DNS/代理）。要 Google 必须 `set`。

## 6. 变更记录

- 2026-08-21：完成静态配置调通（踩坑 A/B/C 三连），沉淀脚本 `scripts/wlp1s0-net.sh` 与本文档。
  - 关键修复：`ipv4.dns-priority -100`（破 DNS 污染）、`ipv4.route-metric 100`（路由优先）、set 后 sleep 5 消除过渡态误报。