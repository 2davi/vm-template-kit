# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# Rocky Linux 공통 정의 (9, 10)
#
# Rocky 고유 처리
# - 템플릿의 NAT 프로필은 NetworkManager keyfile(/etc/NetworkManager/system-connections/*.nmconnection)이다.
#   vmt-clean은 프로필의 MAC 고정 줄만 지운다. 복제본은 MAC이 바뀌어 MAC에 고정된 프로필이 올라오지 않는다
# - vmt-reid는 NIC 구역마다 프로필(vmt-<구역 이름>.nmconnection)을 새로 만든다. NIC는 MAC으로 찾는다
# - SELinux가 켜진 채 설치되므로 새로 쓰거나 고친 파일의 라벨을 restorecon으로 맞춘다
# - SSH 호스트 키는 sshd-keygen@.service가 부팅 때 없는 키만 만든다. 지우기만 하면 된다
# - NetworkManager의 secret_key가 v2(nm-v2:)면 machine-id와 함께 해시되므로
#   machine-id 재생성만으로 DHCP 식별자와 IPv6 안정 주소가 함께 바뀐다
# ─────────────────────────────────────────────────────────────────────────────

ROCKY_NM_DIR=/etc/NetworkManager/system-connections
VMT_NET_CONF=$ROCKY_NM_DIR/vmt-*.nmconnection   # 설명용. 실제 파일은 NIC 구역마다 하나다
VMT_GROWPART_PKG=cloud-utils-growpart
# 값이 MAC 주소인 줄만 고정으로 본다. cloned-mac-address=stable 같은 정책 값은 지우지 않는다
ROCKY_MAC_LINE_RE='^(mac-address|cloned-mac-address)=([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'

rocky_restorecon() {
    command -v restorecon >/dev/null || return 0
    restorecon -F "$@" >/dev/null 2>&1 || vmt_warn "restorecon 실패: $*"
}

# keyfile에 MAC 고정이 있으면 MAC이 바뀐 복제본에서 그 프로필이 올라오지 않는다.
# interface-name이 없는 프로필은 MAC 고정을 지우면 아무 NIC에나 붙을 수 있어 경고한다
rocky_strip_mac_bindings() {
    local f tmp
    for f in "$ROCKY_NM_DIR"/*.nmconnection; do
        [[ -f $f ]] || continue
        grep -Eq "$ROCKY_MAC_LINE_RE" "$f" || continue
        tmp=$(mktemp)
        grep -Ev "$ROCKY_MAC_LINE_RE" "$f" > "$tmp" || true
        vmt_overwrite "$tmp" "$f"
        rocky_restorecon "$f"
        vmt_say "MAC 고정 줄을 지웠다: $f"
        grep -q '^interface-name=' "$f" \
            || vmt_warn "$f에 interface-name이 없다. 복제본에서 NAT가 아닌 NIC에 붙을 수 있다. 'sudo nmcli connection modify <프로필> connection.interface-name <NIC>'로 정한다"
    done
}

# NetworkManager 내장 DHCP 클라이언트의 임대 기록
rocky_remove_nm_leases() {
    find /var/lib/NetworkManager -maxdepth 1 -type f -name '*.lease' -delete 2>/dev/null || true
}

# v1 secret_key는 machine-id와 섞이지 않는다. 지우면 NetworkManager가 다음 시작 때 v2로 만든다
rocky_check_secret_key() {
    local k=/var/lib/NetworkManager/secret_key
    [[ -f $k ]] || return 0
    if [[ $(head -c 6 "$k") != "nm-v2:" ]]; then
        rm -f "$k"
        vmt_say "v1 secret_key를 지웠다. NetworkManager가 다음 시작 때 v2로 다시 만든다"
    fi
}

# vmt-reid가 만든 프로필(이름순)
rocky_vmt_profiles() {
    local f
    for f in "$ROCKY_NM_DIR"/vmt-*.nmconnection; do
        [[ -e $f ]] && printf '%s\n' "$f"
    done
    return 0
}

# 인터페이스를 이름으로 맡는 다른 프로필을 출력한다
rocky_profiles_for() {  # 인터페이스
    local f
    for f in "$ROCKY_NM_DIR"/*.nmconnection; do
        [[ -f $f && ${f##*/} != vmt-*.nmconnection ]] || continue
        grep -qxF "interface-name=$1" "$f" && printf '%s\n' "$f"
    done
    return 0
}

os_network_present() {
    local f
    f=$(rocky_vmt_profiles)
    [[ -n $f ]] && printf '%s\n' "$f"
}

# 만들 프로필 목록(NIC 구역 순서)
os_net_desc() {
    local c out=""
    for c in "${P_NICS[@]}"; do
        out+="${out:+, }$ROCKY_NM_DIR/vmt-$c.nmconnection"
    done
    printf '%s' "${out:-없음}"
}

# ── vmt-clean 훅 ────────────────────────────────────────────────────────────
os_clean_extra() {
    rocky_strip_mac_bindings
    rocky_remove_nm_leases
    rocky_check_secret_key
    # Anaconda가 남긴 Kickstart 기록. 설치 때 고른 값과 계정 비밀번호 해시가 기록되어 있다.
    # 무인 설치에 쓰려면 vmt-clean 전에 따로 보관한다
    rm -f /root/anaconda-ks.cfg /root/original-ks.cfg
    dnf -q clean all >/dev/null 2>&1 || true
}

# ── vmt-reid 훅 ─────────────────────────────────────────────────────────────
os_reid_checks() {
    local c claims
    for c in "${P_NICS[@]}"; do
        claims=$(rocky_profiles_for "${P_IF[$c]}")
        [[ -z $claims ]] \
            || vmt_die "${P_IF[$c]}([nic $c])를 맡는 프로필이 이미 있다: $claims. 지운 뒤 다시 실행한다"
    done
    return 0
}

# NetworkManager는 연결 프로필이 없는 유선 NIC에만 임시 기본 유선 연결(DHCP)을 만든다(NetworkManager.conf의 no-auto-default).
# vmt 프로필이 MAC으로 NIC를 맡으므로 재부팅 뒤에는 그 NIC에 임시 연결이 생기지 않는다
rocky_write_profile() {  # NIC 구역
    local c=$1 m tmp uuid i a r gw mtu dns search
    m=$(pn "$c" method)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    tmp=$(mktemp)
    {
        printf '# vmt-reid %s가 노드 %s의 [nic %s]로 만든 설정이다. 템플릿에는 두지 않는다\n' "$VMT_VERSION" "$P_NODE" "$c"
        printf '# 만들 때 인터페이스 이름: %s\n' "${P_IF[$c]}"
        printf '[connection]\nid=vmt-%s\nuuid=%s\ntype=ethernet\nautoconnect=true\n\n' "$c" "$uuid"
        printf '[ethernet]\nmac-address=%s\n' "${P_MAC[$c]^^}"
        mtu=$(pn "$c" mtu)
        [[ -z $mtu ]] || printf 'mtu=%s\n' "$mtu"
        printf '\n[ipv4]\n'
        case $m in
            static)
                printf 'method=manual\n'
                i=0
                while read -r a; do
                    i=$((i + 1))
                    printf 'address%d=%s\n' "$i" "$a"
                done < <(vmt_list "$(pn "$c" address)")
                gw=$(pn "$c" gateway)
                if [[ -n $gw ]]; then
                    # NAT 쪽 기본 경로(metric 100)보다 앞에 둔다
                    printf 'gateway=%s\nroute-metric=%d\n' "$gw" "$VMT_GW_METRIC"
                else
                    printf 'never-default=true\n'
                fi
                ;;
            dhcp)
                # NAT 쪽 기본 경로보다 뒤에 두어 기본 경로를 빼앗지 않게 한다
                printf 'method=auto\nroute-metric=%d\n' "$VMT_DHCP_METRIC"
                ;;
            off)
                printf 'method=disabled\n'
                ;;
        esac
        i=0
        while read -r r; do
            i=$((i + 1))
            r=$(vmt_route_parse "$r")
            printf 'route%d=%s,%s\n' "$i" "${r% *}" "${r#* }"
        done < <(vmt_list "$(pn "$c" routes)")
        if [[ $c == "$P_DNS_NIC" ]]; then
            dns=$(cfg_node "$P_NODE" dns)
            search=$(cfg_node "$P_NODE" search)
            [[ -z $dns ]] || printf 'dns=%s;\n' "$(vmt_list "$dns" | paste -sd';' -)"
            [[ -z $search ]] || printf 'dns-search=%s;\n' "$(vmt_list "$search" | paste -sd';' -)"
        fi
        printf '\n[ipv6]\n'
        if [[ $m == off ]]; then printf 'method=disabled\n'; else printf 'method=link-local\n'; fi
    } > "$tmp"
    vmt_install_file "$tmp" "$ROCKY_NM_DIR/vmt-$c.nmconnection" 600
}

os_write_network() {
    local c
    # 다시 실행할 때 이전 실행의 프로필(구역 이름이 바뀐 것 포함)을 남기지 않는다
    rm -f "$ROCKY_NM_DIR"/vmt-*.nmconnection
    for c in "${P_NICS[@]}"; do
        rocky_write_profile "$c"
    done
}

os_after_net_edit() {
    local -a files
    mapfile -t files < <(rocky_vmt_profiles)
    rocky_restorecon /etc/hostname /etc/hosts "${files[@]}"
    if systemctl is-active --quiet NetworkManager; then
        nmcli connection reload || vmt_warn "nmcli connection reload 실패. 재부팅 때 반영된다"
    fi
}

# 새 파일 시스템의 최상위 디렉터리에는 SELinux 라벨이 없다
os_after_mount() {  # 마운트 경로
    rocky_restorecon -R "$1"
}

os_ssh_hostkeys() {
    rm -f /etc/ssh/ssh_host_*
    if [[ -f /usr/lib/systemd/system/sshd-keygen@.service ]]; then
        vmt_say "SSH 호스트 키를 지웠다. 재부팅 때 sshd-keygen@.service가 새로 만든다"
    else
        ssh-keygen -A >/dev/null 2>&1 || vmt_die "ssh-keygen -A 실패"
        rocky_restorecon /etc/ssh
    fi
}

os_reset_dhcp() {
    rocky_remove_nm_leases
    rocky_check_secret_key
}

os_reid_finish() {
    rocky_restorecon /etc/machine-id
}
