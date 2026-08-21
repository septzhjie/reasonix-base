#!/usr/bin/env bash
#
# wlp1s0-net.sh —— yoga13 的 wlp1s0（Wi-Fi）网卡静态配置 / 恢复 DHCP 切换脚本
#
# 适用机器：yoga13（Ubuntu 22.04，NetworkManager 管理，root 用户）
# 网卡：wlp1s0（连接名 ZTE-UDzGd3）
#
# 背景：
#   192.168.5.250 是带代理（fake-ip 模式）的网关，只能代理 WiFi(wlp1s0) 口的流量。
#   有线口(br0→192.168.5.1) 的代理流量会被丢弃；且 192.168.5.1 网关会把
#   www.google.com 解析成 127.0.0.1（DNS 污染），导致系统默认走 br0 DNS 时 Google 必不通。
#   因此要给 wlp1s0 设静态（网关/DNS=192.168.5.250）并让 DNS/路由优先。
#   详见 docs/wlp1s0-static-networking.md
#
# 用法：
#   ./wlp1s0-net.sh set      # 设为静态：IP=当前 DHCP 地址、网关=192.168.5.250、DNS=192.168.5.250、路由/DNS 优先
#   ./wlp1s0-net.sh restore  # 恢复：DHCP 自动（清空 IP/网关/DNS/metric/dns-priority）
#   ./wlp1s0-net.sh check    # 只检查（只读），不修改任何配置
#
# 可选环境变量：
#   SSH_TARGET=...  默认 yoga13（本地 ssh 别名）
#   IFACE=wlp1s0    默认 wlp1s0
#   CONN=ZTE-UDzGd3 默认 ZTE-UDzGd3
#   GATEWAY=192.168.5.250  默认 192.168.5.250
#   DNS=192.168.5.250      默认 192.168.5.250
#   RT_METRIC=100  静态模式默认路由 metric（越小越优先，须小于 br0 的 425）
#   DNS_PRIORITY=-100  静态模式 DNS 优先级（负数=优先于 br0 的 0）
#
# 依赖：本地能 ssh 到 yoga13（root），远端有 nmcli / ip / resolvectl。

set -euo pipefail

SSH_TARGET="${SSH_TARGET:-yoga13}"
IFACE="${IFACE:-wlp1s0}"
CONN="${CONN:-ZTE-UDzGd3}"
GATEWAY="${GATEWAY:-192.168.5.250}"
DNS="${DNS:-192.168.5.250}"
RT_METRIC="${RT_METRIC:-100}"
DNS_PRIORITY="${DNS_PRIORITY:--100}"

log()  { printf '\033[1;34m[wlp1s0]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

[ $# -ge 1 ] || usage 1
ACTION="$1"

# ---------- 远端只读检查：当前状态 ----------
remote_status() {
    ssh "$SSH_TARGET" "set -e
    echo '--- 连接配置 (${CONN}) ---'
    nmcli connection show '${CONN}' 2>/dev/null | grep -E 'ipv4\.(method|addresses|gateway|dns|dns-priority|route-metric)' || echo '( 连接不存在! )'
    echo '--- ${IFACE} 生效地址 ---'
    ip -4 addr show '${IFACE}' | grep inet || echo '( 无 IPv4 地址 )'
    echo '--- 默认路由 ---'
    ip route show default || true
    echo '--- 生效 DNS ---'
    nmcli -g IP4.DNS device show '${IFACE}' 2>/dev/null || echo '( 无 )'
    echo '--- 解析 google (验证 DNS 未被 br0 污染) ---'
    resolvectl query www.google.com 2>&1 | head -3 || true
    "
}

do_check() {
    log "检查 yoga13 (${SSH_TARGET}) 当前网络状态（只读）..."
    remote_status
    echo
    echo "期望状态："
    echo "  set     -> ipv4.method=manual, address=${IFACE} 当前地址/24, gateway=${GATEWAY}, dns=${DNS}, dns-priority=${DNS_PRIORITY}, route-metric=${RT_METRIC}"
    echo "  restore -> ipv4.method=auto, addresses/gateway/dns 为空, route-metric=-1, dns-priority=0"
    echo "  google 应解析为 fake-ip (198.18.x.x) 且 -- link: ${IFACE}（若显示 127.0.0.1 -- link: br0 即被 192.168.5.1 污染）"
}

do_set() {
    log "将 ${IFACE} (${CONN}) 设为静态... 网关=${GATEWAY} DNS=${DNS} metric=${RT_METRIC} dns-priority=${DNS_PRIORITY}"
    # 1. 取当前 DHCP 地址（保持 IP 不变），失败则报错
    CUR_IP="$(ssh "$SSH_TARGET" "ip -4 -o addr show '${IFACE}' | awk '{print \$4; exit}'")"
    [ -n "${CUR_IP}" ] || die "无法获取 ${IFACE} 当前 IPv4 地址"
    log "沿用当前地址: ${CUR_IP}"

    # 2. 应用静态配置（幂等；addresses 先清再设，避免叠加多条）
    ssh "$SSH_TARGET" "set -e
    nmcli connection modify '${CONN}' \
        ipv4.method manual \
        ipv4.addresses '' \
        ipv4.gateway '' \
        ipv4.dns '' \
        ipv4.addresses '${CUR_IP}' \
        ipv4.gateway '${GATEWAY}' \
        ipv4.dns '${DNS}' \
        ipv4.route-metric '${RT_METRIC}' \
        ipv4.dns-priority '${DNS_PRIORITY}'
    nmcli connection up '${CONN}'
    "

    # 3. 验证 DNS 解析走 wlp1s0 的 250（防止 br0 抢 DNS 把 google 解析成 127.0.0.1）
    echo
    log "验证 DNS 解析..."
    G_RESULT="$(ssh "$SSH_TARGET" "resolvectl query www.google.com 2>&1 | head -3")"
    echo "$G_RESULT"

    # 4. 连通性验证
    echo
    log "等待路由表稳定 (消除 nmcli up 过渡态)..."
    sleep 5
    log "连通性验证 (Google / baidu)..."
    ssh "$SSH_TARGET" "
        curl -4 -s -o /dev/null -w 'google: HTTP %{http_code}  总耗时 %{time_total}s\n' --connect-timeout 5 -m 12 https://www.google.com || echo 'google: 失败'
        curl -4 -s -o /dev/null -w 'baidu : HTTP %{http_code}  总耗时 %{time_total}s\n' --connect-timeout 5 -m 10 https://www.baidu.com || echo 'baidu: 失败'
    "
    ok "静态配置完成"
}

do_restore() {
    log "将 ${IFACE} (${CONN}) 恢复为 DHCP（清空所有静态项）..."
    ssh "$SSH_TARGET" "set -e
    nmcli connection modify '${CONN}' \
        ipv4.method auto \
        ipv4.addresses '' \
        ipv4.gateway '' \
        ipv4.dns '' \
        ipv4.route-metric -1 \
        ipv4.dns-priority 0
    nmcli connection up '${CONN}'
    "
    echo
    log "验证恢复结果..."
    remote_status
    ok "已恢复 DHCP"
}

case "$ACTION" in
    set)     do_set ;;
    restore) do_restore ;;
    check)   do_check ;;
    -h|--help) usage ;;
    *) die "未知动作: $ACTION （可用: set / restore / check）" ;;
esac