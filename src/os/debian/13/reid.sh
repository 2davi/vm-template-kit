# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-reid · Debian 13 (trixie)
#
# Debian 고유 처리
# - NIC 설정은 /etc/network/interfaces.d/vmt 파일 하나로 새로 만든다.
#   ifupdown은 인터페이스 이름으로 NIC를 찾는다. MAC은 확인용 주석으로 남긴다
# - 주소가 여럿이면 같은 인터페이스의 iface 스탠자를 주소마다 둔다(interfaces(5))
# - dns-nameservers, dns-search는 resolvconf(또는 openresolv)가 있어야 반영된다
# - 설정할 NIC를 다루는 스탠자가 이미 있으면 거부한다
# - SSH 호스트 키는 자동 재생성 장치가 없으므로 바로 만든다(공통 기본 동작)
# - trixie 새 설치는 dhcpcd가 DHCP를 맡는다. dhcpcd는 DUID와 secret을 파일로 저장하고
#   다른 호스트로 복사하지 말라고 안내한다. 지우면 다음 부팅 때 새로 만든다
# ─────────────────────────────────────────────────────────────────────────────

# 인터페이스를 설정하는 스탠자(iface, auto, allow-*)가 있는 파일을 출력한다
debian_iface_declared() {  # 인터페이스
    local f
    for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
        [[ -f $f && $f != "$VMT_NET_CONF" ]] || continue
        awk -v ifc="$1" '
            $1 == "iface" && $2 == ifc { found = 1 }
            $1 ~ /^(auto|allow-)/ { for (i = 2; i <= NF; i++) if ($i == ifc) found = 1 }
            END { exit !found }' "$f" && printf '%s\n' "$f"
    done
    return 0
}

os_reid_checks() {
    local c claims
    (( ${#P_NICS[@]} == 0 )) || debian_sources_interfaces_d \
        || vmt_die "/etc/network/interfaces가 /etc/network/interfaces.d를 읽지 않는다. $DEBIAN_SOURCE_HINT"
    for c in "${P_NICS[@]}"; do
        claims=$(debian_iface_declared "${P_IF[$c]}")
        [[ -z $claims ]] \
            || vmt_die "${P_IF[$c]}([nic $c])를 설정하는 스탠자가 이미 있다: $claims. 지운 뒤 다시 실행한다"
    done
    if [[ -n $P_DNS_NIC && -n $(cfg_node "$P_NODE" dns)$(cfg_node "$P_NODE" search) ]] && ! command -v resolvconf >/dev/null; then
        vmt_warn "resolvconf가 없어 dns-nameservers, dns-search가 반영되지 않는다. 템플릿에 resolvconf 패키지를 설치하거나 /etc/resolv.conf를 고친다"
    fi
    return 0
}

# 경로와 DNS 줄. 첫 스탠자에만 둔다
debian_nic_extras() {  # NIC 구역
    local c=$1 ifc=${P_IF[$1]} r dns search
    while read -r r; do
        r=$(vmt_route_parse "$r")
        printf '    up ip route add %s via %s dev %s\n' "${r% *}" "${r#* }" "$ifc"
        printf '    down ip route del %s via %s dev %s || true\n' "${r% *}" "${r#* }" "$ifc"
    done < <(vmt_list "$(pn "$c" routes)")
    if [[ $c == "$P_DNS_NIC" ]]; then
        dns=$(cfg_node "$P_NODE" dns)
        search=$(cfg_node "$P_NODE" search)
        [[ -z $dns ]] || printf '    dns-nameservers %s\n' "$(vmt_list "$dns" | paste -sd' ' -)"
        [[ -z $search ]] || printf '    dns-search %s\n' "$(vmt_list "$search" | paste -sd' ' -)"
    fi
    return 0
}

os_write_network() {
    local tmp c m ifc a i gw mtu
    if (( ${#P_NICS[@]} == 0 )); then
        rm -f "$VMT_NET_CONF"
        return 0
    fi
    tmp=$(mktemp)
    {
        printf '# vmt-reid %s가 노드 %s에 맞춰 만든 NIC 설정이다. 템플릿에는 두지 않는다\n' "$VMT_VERSION" "$P_NODE"
        for c in "${P_NICS[@]}"; do
            ifc=${P_IF[$c]}
            m=$(pn "$c" method)
            mtu=$(pn "$c" mtu)
            printf '\n# [nic %s] 만들 때 MAC: %s\n' "$c" "${P_MAC[$c]}"
            printf 'allow-hotplug %s\n' "$ifc"
            case $m in
                static)
                    i=0
                    while read -r a; do
                        i=$((i + 1))
                        printf 'iface %s inet static\n    address %s\n' "$ifc" "$a"
                        (( i == 1 )) || continue
                        gw=$(pn "$c" gateway)
                        # NAT 쪽 기본 경로(dhcpcd metric 1000+)보다 앞에 둔다
                        [[ -z $gw ]] || printf '    gateway %s\n    metric %d\n' "$gw" "$VMT_GW_METRIC"
                        [[ -z $mtu ]] || printf '    mtu %s\n' "$mtu"
                        debian_nic_extras "$c"
                    done < <(vmt_list "$(pn "$c" address)")
                    ;;
                dhcp)
                    # metric은 DHCP 클라이언트에 넘어가 기본 경로를 NAT 쪽보다 뒤에 둔다
                    printf 'iface %s inet dhcp\n    metric %d\n' "$ifc" "$VMT_DHCP_METRIC"
                    [[ -z $mtu ]] || printf '    pre-up ip link set dev %s mtu %s\n' "$ifc" "$mtu"
                    debian_nic_extras "$c"
                    ;;
                off)
                    printf 'iface %s inet manual\n' "$ifc"
                    [[ -z $mtu ]] || printf '    mtu %s\n' "$mtu"
                    ;;
            esac
        done
    } > "$tmp"
    vmt_install_file "$tmp" "$VMT_NET_CONF" 644
}

os_reset_dhcp() {
    rm -f /var/lib/dhcpcd/duid /var/lib/dhcpcd/secret
    find /var/lib/dhcpcd -maxdepth 1 -type f \( -name '*.lease' -o -name '*.lease6' \) -delete 2>/dev/null || true
}

vmt_reid_main "$@"
