# yoga13 KVM 虚拟机部署 iStoreOS（旁路由）方案

> 建立日期：2026-08-19 ｜ 适用服务器：yoga13（root，Ubuntu 22.04.5 LTS x86_64）
> 关联文档：无（独立方案）
> 虚拟机名：`istoreos` ｜ 旁路由地址：`192.168.5.250`

## 1. 目标与结论

在 yoga13 笔记本上，用 **KVM/QEMU + libvirt** 虚拟化一台 **iStoreOS 24.10.8**（OpenWrt 系）软路由，**旁路由模式**接入家庭局域网（`192.168.5.0/24`）：

- 关闭 WAN 口（不做拨号/接入）
- 关闭 DHCP 服务（不抢主路由 `192.168.5.1` 的 DHCP）
- LAN 固定 IP `192.168.5.250`，网关/DNS 指向主路由 `192.168.5.1`

**结论：可行，已部署完成并验证通过。** 关键前提是宿主机新增了 USB 有线网卡（r8152），可做 bridge 桥接——纯 Wi-Fi 环境无法实现旁路由。

## 2. 环境与网络拓扑

| 项目 | 值 |
|---|---|
| 宿主机 | yoga13（Jay-Yoga），Ubuntu 22.04.5，物理机（非虚拟机） |
| CPU | AMD Ryzen 5 5600U（6C12T，SVM），`/dev/kvm` 可用 |
| 内存 | 14Gi（可用约 13Gi） |
| 磁盘 | `/` 59G（可用 39G），镜像在 `/var/lib/libvirt/images/` |
| 物理网卡 | Wi-Fi `wlp1s0`（192.168.5.4）+ USB 有线 `enx00e04c680139`（r8152，千兆） |
| 虚拟机 | `istoreos`：2 vCPU / 2048M / qcow2 4G（扩容后） |

```
                    家庭局域网 192.168.5.0/24
 ┌──────────────────────────┼───────────────────────────┐
 │ yoga13 宿主机                                   主路由 192.168.5.1
 │   br0 (192.168.5.3) ── enx00e04c680139 ── 交换机 ──┤ (光猫 192.168.1.1 在其上联侧)
 │     └── vnet2 (virtio)                            │
 │         istoreos VM (br-lan 192.168.5.250)        │
 └──────────────────────────┼───────────────────────────┘
             旁路由用法：设备网关/DNS 指向 192.168.5.250
```

注意：`192.168.1.1` 是**光猫**的管理地址，与 VM 无关；VM 的 LAN 地址是 `192.168.5.250`。

## 3. 部署步骤

### 3.1 网络：USB 有线网卡做 bridge

宿主机 netplan 走 NetworkManager 渲染，用 `nmcli` 建桥：

```bash
# 删除原有线 DHCP 连接（enx00e04c680139 原为 192.168.5.9）
nmcli connection delete "有线连接 1"

# 建桥 br0（DHCP 拿 192.168.5.x），关 STP（单端口无环）
nmcli connection add type bridge con-name br0 ifname br0 ipv4.method auto ipv6.method auto
nmcli connection modify br0 bridge.stp no

# 把有线网卡挂进 br0
nmcli connection add type ethernet con-name bridge-port-enx ifname enx00e04c680139 master br0

nmcli connection up br0
```

验证：`ip -br addr show br0`（当前 `192.168.5.3/24`），`ip route` 默认出口应经 `br0`（Wi-Fi 保留为备份路由）。

### 3.2 安装 libvirt 工具链

```bash
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y libvirt-daemon-system virtinst
systemctl enable --now libvirtd
```

（qemu-system-x86 6.2 / qemu-utils 系统已预装。）

### 3.3 下载 iStoreOS 镜像并转 qcow2

官方源 `fw.koolcenter.com`（国内可达）。最新稳定版为 `istoreos-24.10.8-2026073111`，`combined` = legacy BIOS 引导：

```bash
mkdir -p /var/lib/libvirt/images && cd /var/lib/libvirt/images
curl -sL -o istoreos.img.gz \
  "https://fw.koolcenter.com/iStoreOS/x86_64/istoreos-24.10.8-2026073111-x86-64-squashfs-combined.img.gz"
gunzip -f istoreos.img.gz
qemu-img convert -f raw -O qcow2 istoreos.img istoreos.qcow2
qemu-img resize istoreos.qcow2 4G   # iStoreOS 首次启动自动扩容根分区
rm -f istoreos.img
```

### 3.4 创建虚拟机

```bash
virt-install \
  --name istoreos \
  --memory 2048 \
  --vcpus 2 \
  --disk path=/var/lib/libvirt/images/istoreos.qcow2,format=qcow2,bus=virtio \
  --network bridge=br0,model=virtio \
  --os-variant generic \
  --boot hd \
  --import \
  --noautoconsole

virsh autostart istoreos   # 开机自启
```

### 3.5 关键坑：无图形界面下如何操作 VM（串口方案）

iStoreOS 的 grub 默认启动项 `iStoreOS` 走 **tty1（VGA）**，无显示器时看不到控制台。该镜像 grub.cfg 已内置 `iStoreOS (ttyS0)` 菜单项（index 2），处理如下：

```bash
# 1) 关 VM，挂载 kernel 分区（分区表：p1=kernel ext4 / p2=rootfs squashfs / p3=etc ext4）
modprobe nbd max_part=8
qemu-nbd -c /dev/nbd0 /var/lib/libvirt/images/istoreos.qcow2
mount /dev/nbd0p1 /mnt/ist-kernel

# 2) 默认启动项改为 ttyS0（第 3 个 menuentry，索引 2）
sed -i 's/^set default="0"/set default="2"/' /mnt/ist-kernel/boot/grub/grub.cfg

umount /mnt/ist-kernel && qemu-nbd -d /dev/nbd0

# 3) 给 VM 加 TCP 串口（127.0.0.1:2000，telnet 协议）
cat > /tmp/serial.xml <<'EOF'
<serial type="tcp">
  <source mode="bind" host="127.0.0.1" service="2000"/>
  <protocol type="telnet"/>
  <target port="0"/>
</serial>
EOF
virsh destroy istoreos
virsh attach-device --config istoreos /tmp/serial.xml   # 热插拔不支持，必须 --config + 重启
virsh start istoreos
```

之后用 `nc 127.0.0.1 2000`（或 `telnet 127.0.0.1 2000`）进 VM 串口控制台，iStoreOS 串口自动以 root 登录。

> 排障笔记：libvirt 里若同时存在 pty 和 tcp 两个 `isa-serial`，pty 是 COM1（ttyS0）、tcp 是 COM2（ttyS1），内核 `console=ttyS0` 的输出只会到 pty——所以本方案删掉了 pty 串口，只保留 tcp 串口作为 ttyS0。

### 3.6 旁路由配置（在 VM 串口内执行）

```bash
# LAN 固定 IP（旁路由），网关/DNS 指向主路由
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.5.250'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.5.1'
uci set network.lan.dns='192.168.5.1'

# 删除 WAN 口与 lan6（本镜像 network 配置里本无 wan；删 lan6 避免 DHCPv6 客户端行为）
uci delete network.wan; uci delete network.wan6
uci delete network.lan6

# 关闭 DHCP 服务（dnsmasq 仅保留 DNS 转发）
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'

uci commit
/etc/init.d/network restart
```

## 4. 验证结果

| 检查项 | 结果 |
|---|---|
| 宿主机 ping `192.168.5.250` | ✅ 0.25ms |
| LuCI Web `http://192.168.5.250` | ✅ HTTP 200 |
| SSH `192.168.5.250:22` | ✅ 开放 |
| VM 内 DNS 转发（经 VM 解析域名） | ✅ |
| VM 出网 ping `223.5.5.5` / `baidu.com` | ✅ 3.4ms / 70ms |
| DHCP 关闭（VM dnsmasq 无 dhcp-range） | ✅ |
| 开机自启（`virsh list --autostart`） | ✅ `istoreos` autostart |

## 5. 管理入口与旁路由用法

- **Web 管理**：`http://192.168.5.250`（首次访问会引导设置 root 密码，建议尽快设置）
- **SSH**：`ssh root@192.168.5.250`
- **串口排障**：`nc 127.0.0.1 2000`（在 yoga13 上执行）
- **旁路由用法**：需要走 iStoreOS 的设备（手机/电脑/其他），把网关和 DNS 手动指向 `192.168.5.250`，即可在 iStoreOS 安装插件（AdGuard Home、科学上网等）接管流量。

## 6. 注意事项 / 已知取舍

1. 防火墙 zone 保留了无接口的 `wan` zone 引用（无害，未删除）；如要彻底清理需按索引删除 `firewall.@zone[1]` 等条目。
2. VM 磁盘扩容到 4G，iStoreOS 首次启动自动扩容；如后续需要更大空间，先 `qemu-img resize` 再在 VM 内用 diskman 扩分区。
3. 旁路由的 VM 在 DHCP 关闭后只做二层透传 + 三层转发；若需 DHCP 分配能力，改 `uci set dhcp.lan.ignore='0'`。
4. 镜像源 `fw.koolcenter.com` 为国内 CDN；GitHub release 亦可（网络环境而定）。
5. 宿主机 `br0` 当前 IP 为 `192.168.5.3`（原 USB 网卡的 `192.168.5.9` 已随桥接迁移）。

## 7. 维护虚拟机的常用命令

### 生命周期

```bash
virsh list --all                # 列出所有虚拟机（--all 含已关机）
virsh start istoreos            # 启动
virsh shutdown istoreos         # 优雅关机（ACPI）
virsh destroy istoreos          # 强制关机（等同拔电）
virsh reboot istoreos           # 重启
virsh autostart istoreos        # 设置开机自启（--disable 取消）
virsh dominfo istoreos          # 虚拟机概要（内存/CPU/状态/自启）
virsh domstate istoreos         # 状态
virsh vcpuinfo istoreos         # vCPU 使用
virsh dommemstat istoreos       # 内存统计
```

### 配置查看与修改

```bash
virsh dumpxml istoreos          # 导出 XML 配置（--inactive 显示持久配置）
virsh edit istoreos             # 编辑 XML（修改后需重启 VM 生效）
virsh attach-device --config istoreos /path/dev.xml    # 添加设备（--live 热插拔）
virsh detach-device --config istoreos /path/dev.xml    # 移除设备
virsh vcpucount istoreos        # 查看 vCPU 数
virsh setvcpus istoreos --count 4 --live --config      # 在线加 vCPU（需要热插拔支持）
virsh setmem istoreos --size 4G --live --config        # 在线调内存
```

### 磁盘与快照

```bash
qemu-img info /var/lib/libvirt/images/istoreos.qcow2          # 镜像信息
qemu-img resize /var/lib/libvirt/images/istoreos.qcow2 8G     # 扩容（需关机；VM 内再扩分区）
virsh snapshot-list istoreos                 # 快照列表
virsh snapshot-create-as istoreos snap1 "desc"    # 建快照（qcow2 需支持）
virsh snapshot-revert istoreos snap1         # 回滚快照（需关机）
virsh snapshot-delete istoreos snap1         # 删快照
virsh blockcopy istoreos vda /path/backup.qcow2 --pivot   # 在线热迁移/备份磁盘
```

### 网络

```bash
virsh domiflist istoreos        # 虚拟机网卡与对应 vnet 口
ip -br link show br0            # 宿主机网桥状态
bridge link show br0            # 桥上的端口（enx...、vnetX）
nmcli connection show br0       # NetworkManager 桥连接配置
virsh net-list --all            # libvirt 网络（默认 virbr0 未使用）
```

### 串口与控制台

```bash
nc 127.0.0.1 2000               # 连 VM 串口（本部署添加的 tcp 串口，ttyS0）
virsh console istoreos          # 连 pty 串口控制台（本部署已删 pty，慎用）
```

### 日志与排障

```bash
journalctl -u libvirtd -f       # libvirtd 日志
virsh dominfo istoreos | grep -i cpu   # CPU 时间（看是否在运行）
ps aux | grep qemu-system       # 查看 QEMU 进程与参数
```

### 删除虚拟机（如需重建）

```bash
virsh destroy istoreos
virsh undefine istoreos --remove-all-storage   # 删除定义 + 磁盘（慎用，会删数据）
```
