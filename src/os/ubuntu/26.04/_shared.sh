# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# Ubuntu Server 26.04 LTS: vmt-clean, vmt-reid, vmt-nodes가 함께 쓰는 정의

os_require() { vmt_require_os ubuntu 26.04; }

# vmt-reid가 복제본에 만드는 NIC 설정. 템플릿의 netplan 파일(50-cloud-init.yaml)은 건드리지 않는다
VMT_NET_CONF=/etc/netplan/60-vmt.yaml

ubuntu_netplan_files() {
    local f
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [[ -f $f ]] && printf '%s\n' "$f"
    done
    return 0
}
