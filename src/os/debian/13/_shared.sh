# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# Debian 13 (trixie): vmt-clean, vmt-reid, vmt-nodes가 함께 쓰는 정의

os_require() {
    vmt_require_os debian 13
    # PVE도 /etc/os-release가 debian 13이다. PVE 노드는 pve/9 스크립트를 쓴다
    if command -v pveversion >/dev/null; then
        vmt_die "Proxmox VE 노드다. pve/9의 스크립트를 쓴다"
    fi
}

# vmt-reid가 복제본에 만드는 NIC 설정. /etc/network/interfaces가 이 디렉터리를 읽어야 한다
VMT_NET_CONF=/etc/network/interfaces.d/vmt

debian_sources_interfaces_d() {
    grep -Eq '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d(/\*)?/?[[:space:]]*$' \
        /etc/network/interfaces 2>/dev/null
}

# vmt-clean과 vmt-reid가 읽는다. 같은 파일이 묶이는 vmt-nodes에서는 쓰이지 않는다
# shellcheck disable=SC2034
DEBIAN_SOURCE_HINT="'source /etc/network/interfaces.d/*' 줄을 /etc/network/interfaces에 더한다"
