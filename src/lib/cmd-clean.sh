# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-clean: 템플릿 정리
#
# 템플릿 VM에서 실행한다. NAT 인터페이스와 MAC을 template.env에 기록하고,
# 복제본에 넘기면 안 되는 상태를 지운다. 노드 목록(nodes.conf)이 있으면 검사한다.
# ─────────────────────────────────────────────────────────────────────────────

vmt_clean_usage() {
    cat <<EOF
사용법: sudo $0 [--poweroff]

템플릿 VM에서 실행한다. 템플릿은 NAT NIC 하나(DHCP)로 만든다.
NAT 인터페이스와 MAC을 $VMT_TEMPLATE_ENV에 기록하고, 복제본에 넘기면 안 되는 상태
(random-seed, credential.secret, 설치 기록, 셸 기록, DHCP 임대 기록)를 지운다.
노드 목록($VMT_NODES_CONF)이 있으면 형식과 값을 검사한다. 오류가 있으면 아무것도 지우지 않는다.
끝나면 전원을 끄고 스냅샷(VirtualBox)이나 부모 디스크(Hyper-V)를 만든다.

  --poweroff   정리가 끝나면 바로 전원을 끈다
  --version    버전을 출력한다
EOF
}

# 모든 OS에 공통인 정리 단계
vmt_clean_common() {
    if command -v journalctl >/dev/null; then
        journalctl --rotate >/dev/null 2>&1 || true
        journalctl --vacuum-time=1s >/dev/null 2>&1 || true
    fi
    # random-seed: 서비스를 먼저 멈춰 종료 시 저장을 끝낸 뒤 지운다. 그래야 poweroff 때 다시 쓰지 않는다
    systemctl stop systemd-random-seed.service >/dev/null 2>&1 || true
    rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret
    # 셸 기록: root와 sudo를 실행한 사용자
    rm -f /root/.bash_history
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        local home
        home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        [[ -n $home ]] && rm -f "$home/.bash_history"
    fi
}

vmt_clean_main() {
    local poweroff=0
    while (( $# )); do
        case $1 in
            -h|--help)  vmt_clean_usage; exit 0 ;;
            --version)  printf '%s %s\n' "$PROG" "$VMT_VERSION"; exit 0 ;;
            --poweroff) poweroff=1 ;;
            *)          vmt_clean_usage >&2; exit 2 ;;
        esac
        shift
    done
    vmt_require_root
    os_require
    vmt_require_ip
    [[ ! -e $VMT_REID_STAMP ]] \
        || vmt_die "이 VM은 vmt-reid를 실행한 복제본이다($VMT_REID_STAMP). 복제본을 새 템플릿으로 쓰려면 이 파일과 관리망 설정을 지운 뒤 다시 실행한다"
    local netconf
    if netconf=$(os_network_present); then
        vmt_die "vmt-reid가 만든 NIC 설정이 남아 있다: ${netconf//$'\n'/, }. 템플릿에는 NAT NIC 설정만 둔다. 지운 뒤 다시 실행한다"
    fi
    # 노드 목록은 복제본의 vmt-reid가 읽는다. 오류가 있는 목록을 템플릿에 굳히지 않는다
    local nodes="없음"
    if [[ -f $VMT_NODES_CONF ]]; then
        vmt_cfg_load_checked "$VMT_NODES_CONF"
        nodes="$VMT_NODES_CONF (${CFG_NODES:-노드 없음})"
    fi

    TPL_HOST=$(hostname -s)
    vmt_valid_hostname "$TPL_HOST" || vmt_die "호스트명 형식이 맞지 않다: $TPL_HOST"
    TPL_FQDN=$(vmt_hosts_fqdn /etc/hosts "$TPL_HOST")
    # /etc/hostname에 FQDN을 적는 배포판도 있다(Rocky 설치 프로그램에 FQDN을 넣은 경우)
    if [[ -z $TPL_FQDN && -r /etc/hostname ]]; then
        local static
        static=$(head -n1 /etc/hostname | tr -d '[:space:]')
        [[ $static == "$TPL_HOST".* ]] && TPL_FQDN=$static
    fi

    # NAT NIC: 기본 경로를 가진 인터페이스. 복제본에서 관리망 NIC와 구분하는 기준이 된다
    local -a defs
    mapfile -t defs < <(vmt_default_ifaces)
    (( ${#defs[@]} == 1 )) \
        || vmt_die "기본 경로를 가진 인터페이스가 하나여야 한다. 찾은 인터페이스: ${defs[*]:-없음}. 템플릿은 NAT NIC 하나로 만들고 DHCP로 주소를 받는다"
    TPL_IFACE=${defs[0]}
    TPL_CIDR=$(vmt_iface_cidr "$TPL_IFACE")
    TPL_MAC=$(os_template_mac)
    [[ -n $TPL_MAC ]] || vmt_die "템플릿 판별에 쓸 MAC 주소를 읽지 못했다"

    # 템플릿에 NAT NIC 말고 다른 NIC가 있으면 복제본도 그대로 물려받는다
    local -a extra=()
    local n
    while read -r n; do
        [[ -n $n && $n != "$TPL_IFACE" ]] && extra+=("$n")
    done < <(vmt_physical_nics)
    if (( ${#extra[@]} )); then
        vmt_warn "템플릿에 NAT 말고 NIC가 더 있다: ${extra[*]}. 복제본이 그대로 물려받아 interface = auto의 후보가 된다. 템플릿에는 NAT NIC만 둔다"
    fi

    os_clean_checks
    vmt_template_env_write
    os_clean_extra
    vmt_clean_common

    vmt_say "== vmt-clean 결과 =="
    vmt_say "템플릿         : $TPL_HOST${TPL_FQDN:+ ($TPL_FQDN)}"
    vmt_say "NAT 인터페이스 : $TPL_IFACE (${TPL_CIDR:-주소 없음}, MAC $TPL_MAC)"
    vmt_say "기록 파일      : $VMT_TEMPLATE_ENV"
    vmt_say "노드 목록      : $nodes"
    if (( poweroff )); then
        vmt_say "전원을 끈다"
        systemctl poweroff
    else
        vmt_say "다음 순서: sudo poweroff, 그다음 호스트에서 스냅샷(VirtualBox)이나 부모 디스크(Hyper-V)를 만든다"
    fi
}
