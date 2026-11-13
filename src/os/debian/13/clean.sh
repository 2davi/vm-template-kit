# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-clean · Debian 13 (trixie)
#
# Debian 고유 처리
# - 복제본의 NIC 설정은 /etc/network/interfaces.d에 생긴다. interfaces가 그 디렉터리를 읽어야 한다
# - 설치 관리자의 cdebconf 데이터베이스(/var/log/installer/cdebconf)에는 민감한 정보가 남을 수 있어 지운다
# - dhcpcd 임대 기록을 지운다. DUID와 secret은 복제본에서 vmt-reid가 지운다
# ─────────────────────────────────────────────────────────────────────────────

os_clean_checks() {
    # 데스크톱 작업을 고르면 NetworkManager가 들어와 ifupdown 설정과 같이 움직인다
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        vmt_warn "NetworkManager가 실행 중이다. NAT 인터페이스를 ifupdown이 맡는지 확인한다"
    fi
    debian_sources_interfaces_d \
        || vmt_die "/etc/network/interfaces가 /etc/network/interfaces.d를 읽지 않는다. 복제본의 NIC 설정이 그 디렉터리에 생긴다. $DEBIAN_SOURCE_HINT"
}

os_clean_extra() {
    rm -rf /var/log/installer/cdebconf
    find /var/lib/dhcpcd -maxdepth 1 -type f \( -name '*.lease' -o -name '*.lease6' \) -delete 2>/dev/null || true
    apt-get clean
}

vmt_clean_main "$@"
