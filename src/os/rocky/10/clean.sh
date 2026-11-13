# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-clean · Rocky Linux 10
#
# Rocky 공통 처리는 src/os/rocky/_family.sh에 있다.
# 10 고유 처리
# - NetworkManager가 ifcfg 형식을 더는 읽지 않는다. ifcfg 파일이 남아 있으면 쓰이지 않는 설정이라 경고만 한다
# ─────────────────────────────────────────────────────────────────────────────

os_clean_checks() {
    local f
    for f in /etc/sysconfig/network-scripts/ifcfg-*; do
        [[ -f $f && ${f##*/} != ifcfg-lo ]] \
            && vmt_warn "$f는 Rocky 10에서 쓰이지 않는 ifcfg 설정이다. 정리해 둔다"
    done
    return 0
}

vmt_clean_main "$@"
