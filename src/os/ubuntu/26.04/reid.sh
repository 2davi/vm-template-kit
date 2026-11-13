# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-reid · Ubuntu Server 26.04 LTS
#
# Ubuntu 고유 처리
# - NIC 설정은 netplan 파일 하나(60-vmt.yaml)로 새로 만든다. NIC 구역마다 항목 vmt-<구역 이름>을 두고
#   MAC으로 NIC를 찾는다(match.macaddress)
# - 템플릿의 netplan 설정이 같은 NIC도 맡으면(같은 이름의 항목, glob 이름 조건) 거부한다.
#   networkd는 한 NIC에 맞는 설정 파일 가운데 이름순으로 처음 것만 쓰므로 vmt 설정이 무시될 수 있다
# - netplan generate로 문법만 검사한다. 적용은 재부팅 때 한다
# - SSH 호스트 키는 자동 재생성 장치가 없으므로 바로 만든다(공통 기본 동작)
# - DHCP DUID는 machine-id에서 계산되므로 machine-id 재생성으로 함께 바뀐다
# ─────────────────────────────────────────────────────────────────────────────

# 인터페이스를 맡는 다른 netplan 파일을 출력한다. YAML을 해석하지 않고 줄 단위로 두 가지만 본다.
#   - 장치 ID가 인터페이스 이름인 항목(    enp0s8:)
#   - match.name 값(glob 포함)이 인터페이스 이름과 맞는 항목
ubuntu_netplan_claims() {  # 인터페이스
    local f line
    while read -r f; do
        [[ -n $f && $f != "$VMT_NET_CONF" ]] || continue
        while IFS= read -r line; do
            line=${line%%#*}
            if [[ $line =~ ^[[:space:]]+([A-Za-z0-9._-]+):[[:space:]]*$ && ${BASH_REMATCH[1]} == "$1" ]]; then
                printf '%s\n' "$f"
                break
            fi
            if [[ $line =~ ^[[:space:]]+name:[[:space:]]*[\"\']?([^\"\'[:space:]]+)[\"\']?[[:space:]]*$ ]]; then
                # shellcheck disable=SC2053  # 오른쪽은 netplan의 glob 패턴이다
                if [[ $1 == ${BASH_REMATCH[1]} ]]; then
                    printf '%s\n' "$f"
                    break
                fi
            fi
        done < "$f"
    done < <(ubuntu_netplan_files)
}

os_reid_checks() {
    local c claims
    for c in "${P_NICS[@]}"; do
        claims=$(ubuntu_netplan_claims "${P_IF[$c]}")
        [[ -z $claims ]] \
            || vmt_die "다른 netplan 설정이 ${P_IF[$c]}([nic $c])를 맡는다: $claims. 그 설정에서 ${P_IF[$c]} 항목이나 이름 조건을 지운 뒤 다시 실행한다"
    done
    return 0
}

# YAML 흐름 목록: [a, b]
ubuntu_yaml_list() {  # 쉼표 목록
    printf '[%s]' "$(vmt_list "$1" | paste -sd, - | sed 's/,/, /g')"
}

os_write_network() {
    local tmp c m a r gw mtu dns search
    if (( ${#P_NICS[@]} == 0 )); then
        rm -f "$VMT_NET_CONF"
        return 0
    fi
    tmp=$(mktemp)
    {
        printf '# vmt-reid %s가 노드 %s에 맞춰 만든 NIC 설정이다. 템플릿에는 두지 않는다\n' "$VMT_VERSION" "$P_NODE"
        printf 'network:\n  version: 2\n  ethernets:\n'
        for c in "${P_NICS[@]}"; do
            m=$(pn "$c" method)
            printf '    vmt-%s:\n' "$c"
            printf '      # 만들 때 인터페이스 이름: %s\n' "${P_IF[$c]}"
            printf '      match:\n        macaddress: "%s"\n' "${P_MAC[$c]}"
            if [[ $m == dhcp ]]; then
                # NAT 쪽 기본 경로보다 뒤에 두어 기본 경로를 빼앗지 않게 한다
                printf '      dhcp4: true\n      dhcp4-overrides:\n        route-metric: %d\n' "$VMT_DHCP_METRIC"
            else
                printf '      dhcp4: false\n'
            fi
            printf '      dhcp6: false\n'
            [[ $m != off ]] || printf '      link-local: []\n'
            if [[ $m == static ]]; then
                printf '      addresses:\n'
                while read -r a; do printf '        - %s\n' "$a"; done < <(vmt_list "$(pn "$c" address)")
            fi
            mtu=$(pn "$c" mtu)
            [[ -z $mtu ]] || printf '      mtu: %s\n' "$mtu"
            gw=$(pn "$c" gateway)
            if [[ -n $gw$(pn "$c" routes) ]]; then
                printf '      routes:\n'
                [[ -z $gw ]] || printf '        - to: default\n          via: %s\n          metric: %d\n' "$gw" "$VMT_GW_METRIC"
                while read -r r; do
                    r=$(vmt_route_parse "$r")
                    printf '        - to: %s\n          via: %s\n' "${r% *}" "${r#* }"
                done < <(vmt_list "$(pn "$c" routes)")
            fi
            if [[ $c == "$P_DNS_NIC" ]]; then
                dns=$(cfg_node "$P_NODE" dns)
                search=$(cfg_node "$P_NODE" search)
                if [[ -n $dns$search ]]; then
                    printf '      nameservers:\n'
                    [[ -z $dns ]] || printf '        addresses: %s\n' "$(ubuntu_yaml_list "$dns")"
                    [[ -z $search ]] || printf '        search: %s\n' "$(ubuntu_yaml_list "$search")"
                fi
            fi
            printf '      optional: true\n'
        done
    } > "$tmp"
    vmt_install_file "$tmp" "$VMT_NET_CONF" 600
}

os_after_net_edit() {
    [[ -e $VMT_NET_CONF ]] || return 0
    if command -v netplan >/dev/null; then
        netplan generate || vmt_die "netplan generate 실패. 확인할 파일: $VMT_NET_CONF"
    fi
}

vmt_reid_main "$@"
