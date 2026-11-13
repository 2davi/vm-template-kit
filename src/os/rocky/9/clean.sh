# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-clean · Rocky Linux 9
#
# Rocky 공통 처리는 src/os/rocky/_family.sh에 있다.
# 9 고유 처리
# - NetworkManager가 ifcfg 형식(/etc/sysconfig/network-scripts/ifcfg-*)을 아직 읽는다.
#   vmt-clean은 keyfile의 MAC 고정만 지우므로, ifcfg 프로필의 HWADDR 고정은 복제본에서 NAT 프로필을 막는다.
#   ifcfg 프로필이 있으면 거부하고 keyfile로 옮기게 한다
# ─────────────────────────────────────────────────────────────────────────────

os_clean_checks() {
    local f
    local -a ifcfg=()
    for f in /etc/sysconfig/network-scripts/ifcfg-*; do
        [[ -f $f && ${f##*/} != ifcfg-lo ]] && ifcfg+=("$f")
    done
    (( ${#ifcfg[@]} == 0 )) \
        || vmt_die "ifcfg 형식 프로필이 있다: ${ifcfg[*]}. 'sudo nmcli connection migrate'로 keyfile로 옮긴 뒤 다시 실행한다"
}

vmt_clean_main "$@"
