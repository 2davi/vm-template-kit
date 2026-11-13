# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-clean · Proxmox VE 9
# ─────────────────────────────────────────────────────────────────────────────

# 브리지 MAC 대신 포트(물리 NIC)의 MAC을 쓴다. 포트 MAC은 복제 때 반드시 새로 만들어진다
os_template_mac() {
    local port
    port=$(pve_bridge_port "$TPL_IFACE")
    [[ -n $port ]] || vmt_die "$TPL_IFACE의 bridge-ports를 /etc/network/interfaces에서 찾지 못했다"
    vmt_mac_of "$port"
}

os_clean_checks() {
    [[ $TPL_IFACE == vmbr* ]] || vmt_die "기본 경로가 브리지(vmbr*)에 있지 않다: $TPL_IFACE. NAT 주소는 vmbr0에 둔다"
    pve_require_standalone
    pve_require_no_pinning
}

os_clean_extra() {
    apt-get clean
}

vmt_clean_main "$@"
