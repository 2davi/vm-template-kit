# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-clean · Ubuntu Server 26.04 LTS
#
# Ubuntu 고유 처리
# - 설치 프로그램이 남긴 autoinstall-user-data에는 계정 정보가 기록되어 있으므로 지운다
# - cloud-init이 켜져 있으면 복제본 첫 부팅 때 netplan 설정과 /etc/hosts를 다시 만들 수 있어 경고한다
# - NAT 설정이 MAC으로 NIC를 찾으면(match.macaddress) MAC이 바뀐 복제본에서 붙지 않으므로 경고한다
# - DHCP 식별자(DUID)는 systemd-networkd가 machine-id에서 계산하므로 따로 지울 상태가 없다
# ─────────────────────────────────────────────────────────────────────────────

os_clean_checks() {
    # 설치 프로그램은 설치 뒤 cloud-init을 꺼 둔다(/etc/cloud/cloud-init.disabled)
    if [[ -d /etc/cloud && ! -e /etc/cloud/cloud-init.disabled ]]; then
        vmt_warn "cloud-init이 켜져 있다. 복제본 첫 부팅 때 netplan 설정과 /etc/hosts를 다시 만들 수 있다"
    fi
    local f mode
    while read -r f; do
        [[ -n $f ]] || continue
        # netplan은 다른 사용자가 읽을 수 있는 설정 파일에 경고를 낸다
        mode=$(stat -c %a "$f")
        [[ $mode == 600 ]] || vmt_warn "$f 권한이 $mode다. 600으로 둔다: sudo chmod 600 $f"
        if grep -Eq '^[[:space:]]+macaddress:' "$f"; then
            vmt_warn "$f가 MAC으로 NIC를 찾는다(macaddress). 복제본은 MAC이 바뀌어 이 설정이 붙지 않는다. 인터페이스 이름으로 바꾼다"
        fi
    done < <(ubuntu_netplan_files)
}

os_clean_extra() {
    # 같은 설치를 반복하기 위한 파일. identity 항목에 계정과 비밀번호 해시가 기록되어 있다
    rm -f /var/log/installer/autoinstall-user-data
    apt-get clean
}

vmt_clean_main "$@"
