# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# Proxmox VE 9: vmt-clean, vmt-reid, vmt-nodes가 함께 쓰는 정의
#
# 전제: 클러스터에 가입하지 않은 단독 노드, VM과 CT 없음, 인터페이스 이름 고정(.link) 없음.
# 템플릿의 NAT 주소는 vmbr0 브리지에 정적으로 둔다(VirtualBox NAT: 10.0.2.15/24, 게이트웨이 10.0.2.2).
# 템플릿 판별에는 브리지 포트(물리 NIC)의 MAC을 쓴다.
# ─────────────────────────────────────────────────────────────────────────────

os_require() {
    vmt_require_os debian 13
    command -v pveversion >/dev/null || vmt_die "pveversion이 없다. Proxmox VE 노드가 아니다"
    local major
    major=$(pveversion | sed -n 's#^pve-manager/\([0-9][0-9]*\)\..*#\1#p')
    [[ $major == 9 ]] || vmt_die "이 스크립트는 Proxmox VE 9 전용이다. 현재: $(pveversion)"
}

# vmt-reid는 NIC 구역마다 그 NIC를 포트로 쓰는 브리지 스탠자를 /etc/network/interfaces 끝에 더한다.
# 스탠자 안의 주석 줄(#vmt-reid nic <구역 이름>)은 PVE 웹 UI에서 그 브리지의 설명(Comment)으로 보인다
VMT_NET_CONF=/etc/network/interfaces
PVE_MARK_PREFIX="#vmt-reid nic "

os_network_present() {
    grep -q "^$PVE_MARK_PREFIX" "$VMT_NET_CONF" 2>/dev/null && printf '%s\n' "$VMT_NET_CONF"
}

# PVE 노드 구성 규칙. 노드 IP는 고정 주소이고 기본 경로는 vmbr0(NAT)에 있다
os_cfg_validate_node() {  # 노드
    local n=$1 c m static=0
    local -a addrs
    for c in ${CFG_NICS[$n]-}; do
        m=$(cfg_nic "$n" "$c" method)
        case $m in
            static) static=1 ;;
            dhcp)   cfg_err_at "nic.$n.$c.method" "[node $n] [nic $c] PVE에서는 method = dhcp를 쓰지 않는다. static이나 off(주소 없는 브리지)를 쓴다" ;;
        esac
        [[ -z ${CFG[nic.$n.$c.gateway]-} ]] \
            || cfg_err_at "nic.$n.$c.gateway" "[node $n] [nic $c] PVE에서는 gateway를 쓰지 않는다. 기본 경로는 vmbr0(NAT)에 있다"
        [[ -z ${CFG[nic.$n.$c.routes]-} ]] \
            || cfg_err_at "nic.$n.$c.routes" "[node $n] [nic $c] PVE에서는 routes를 쓰지 않는다. 필요하면 웹 UI나 /etc/network/interfaces에서 더한다"
        mapfile -t addrs < <(vmt_list "${CFG[nic.$n.$c.address]-}")
        (( ${#addrs[@]} <= 1 )) \
            || cfg_err_at "nic.$n.$c.address" "[node $n] [nic $c] PVE에서는 브리지마다 주소를 하나만 쓴다"
    done
    (( static )) || cfg_err_at "node.$n" "[node $n] PVE 노드에는 method = static인 NIC가 하나 이상 있어야 한다. 그 주소가 노드 IP가 된다"
    return 0
}

# 브리지 스탠자의 첫 번째 bridge-ports 값을 출력한다
pve_bridge_port() {
    awk -v br="$1" '
        $1 == "iface"                         { inb = ($2 == br); next }
        $1 ~ /^(auto|allow-|source|mapping)/  { inb = 0 }
        inb && $1 == "bridge-ports"           { print $2; exit }' /etc/network/interfaces
}

pve_require_standalone() {
    [[ ! -e /etc/pve/corosync.conf ]] || vmt_die "클러스터에 가입한 노드다. 단독 노드에서만 쓴다"
    ! compgen -G '/etc/pve/nodes/*/qemu-server/*.conf' >/dev/null || vmt_die "VM이 있다. 빈 노드에서만 쓴다"
    ! compgen -G '/etc/pve/nodes/*/lxc/*.conf' >/dev/null       || vmt_die "CT가 있다. 빈 노드에서만 쓴다"
}

# PVE 9.1부터 설치 관리자가 MAC으로 NIC 이름을 고정하는 .link 파일을 만들 수 있다.
# 복제본은 MAC이 바뀌므로 이름이 원래대로 돌아가 브리지 포트를 잃는다
pve_require_no_pinning() {
    ! compgen -G '/usr/local/lib/systemd/network/*.link' >/dev/null \
        || vmt_die "인터페이스 이름 고정(.link)이 켜져 있다. 복제본은 MAC이 바뀌어 브리지 포트를 잃는다"
}
