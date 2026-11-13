# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-reid · Proxmox VE 9
#
# PVE는 노드 이름이 /etc/pve(pmxcfs)의 노드 디렉터리와 노드 인증서에 기록되어 있어 두 단계로 나눈다.
#   1단계: vmt-reid (메뉴, --node, 또는 <새 FQDN> <새 IP/접두>)  → reboot
#   2단계: vmt-reid --finish
# 1단계는 NIC 구역마다 그 NIC를 포트로 쓰는 브리지(vmbr1부터 빈 번호)를 /etc/network/interfaces에 더하고,
# /etc/hosts의 노드 IP를 첫 고정 주소 브리지로 옮긴다. vmbr0(NAT)은 그대로 둔다.
# 호스트명, postfix 이름, machine-id, SSH 호스트 키, 추가 디스크, 루트 확장도 1단계에서 처리한다.
# 실행 중인 호스트명은 바꾸지 않는다. pmxcfs가 재부팅 때 새 이름으로 올라와야 새 노드 디렉터리가 생긴다.
# 2단계는 옛 노드 디렉터리, root SSH 키 쌍, 클러스터 CA, 노드 인증서, authkey를 새로 만든다.
# pveproxy는 시작 전에 pvecm updatecerts를 실행하므로 재부팅 때 템플릿 CA로 새 노드 인증서가 먼저 생긴다.
# 2단계에서 그 CA와 인증서를 지우고 --force로 다시 발급한다.
# PVE에는 sudo가 기본으로 없다. 안내 문구는 root 셸 기준으로 쓴다.
# ─────────────────────────────────────────────────────────────────────────────

PVE_STAGE=$VMT_STATE/pve-stage1   # 1단계가 2단계로 넘기는 값
VMT_RENAME_RUNTIME=0
declare -A PVE_BR=()             # NIC 구역별로 만든 브리지

# 공통 사용법을 PVE용으로 바꾼다(뒤에 정의한 함수가 이긴다)
vmt_reid_usage() {
    cat <<EOF
사용법:
  1단계: $PROG                                   메뉴에서 노드를 골라 적용한다
         $PROG --node <노드> [--config <파일>]   노드 목록의 노드를 적용한다
         $PROG [--iface <인터페이스>] <새 FQDN 또는 호스트명> <새 IP/접두>
         예) $PROG pve-01.lab.internal 192.168.56.21/24
         끝나면 reboot
  2단계: $PROG --finish

복제본에서 root로 실행한다. 클러스터에 가입하지 않은 빈 노드에서만 쓴다.
1단계는 NIC마다 그 NIC를 포트로 쓰는 브리지(vmbr1 등)를 만들고 노드 IP를 첫 고정 주소 브리지로 옮긴다.
vmbr0(NAT)은 그대로 둔다. 노드 목록 기본 위치: $VMT_NODES_CONF

  --check      바꾸지 않고 적용 계획만 출력한다
  --iface IF   (호스트명·IP로 실행할 때) NIC를 직접 지정한다
  --version    버전을 출력한다
EOF
}

# 설정 파일에 선언된 인터페이스 이름
pve_declared_names() {  # 파일
    awk '$1 == "iface" { print $2 } $1 ~ /^(auto|allow-)/ { for (i = 2; i <= NF; i++) print $i }' "$1"
}

# 쓰지 않는 vmbrN 가운데 가장 작은 이름 (1부터)
pve_free_bridge() {  # 선언된 이름 목록(줄 단위)
    local n=1
    while grep -qxF "vmbr$n" <<<"$1" || [[ -e /sys/class/net/vmbr$n ]]; do
        n=$((n + 1))
    done
    printf 'vmbr%d\n' "$n"
}

# NIC 구역마다 쓸 브리지 이름을 정한다. 원본 설정 파일 기준이라 계획과 적용에서 같은 결과가 나온다
pve_assign_bridges() {
    local names c br
    names=$(pve_declared_names "$(vmt_orig /etc/network/interfaces)")
    PVE_BR=()
    for c in "${P_NICS[@]}"; do
        br=$(pve_free_bridge "$names")
        names+=$'\n'"$br"
        PVE_BR[$c]=$br
    done
}

os_reid_checks() {
    local c
    [[ ! -e $PVE_STAGE ]] || vmt_die "1단계를 이미 했다. reboot 한 뒤 $PROG --finish"
    pve_assign_bridges
    pve_require_standalone
    pve_require_no_pinning
    # NIC에 이미 주소가 설정되어 있거나 다른 브리지의 포트이면 거부한다. "inet manual" 선언은 그대로 둔다
    for c in "${P_NICS[@]}"; do
        awk -v ifc="${P_IF[$c]}" '
            $1 == "iface" && $2 == ifc && $4 != "manual" { bad = 1 }
            $1 ~ /^bridge[-_]ports$/ { for (i = 2; i <= NF; i++) if ($i == ifc) bad = 1 }
            END { exit bad }' "$(vmt_orig /etc/network/interfaces)" \
            || vmt_die "/etc/network/interfaces가 ${P_IF[$c]}([nic $c])를 이미 쓴다(주소 설정이나 브리지 포트). 지운 뒤 다시 실행한다"
    done
    if [[ -n $(cfg_node "$P_NODE" dns)$(cfg_node "$P_NODE" search) ]]; then
        vmt_warn "PVE에서는 dns, search를 적용하지 않는다. 웹 UI의 System > DNS에서 바꾼다"
    fi
    return 0
}

# 원본 끝에 NIC 구역마다 브리지 스탠자를 더한다. 다시 실행해도 원본에서 다시 만든다
os_write_network() {
    local orig tmp names c ifc br mtu a
    vmt_backup_once /etc/network/interfaces
    orig=$(vmt_orig /etc/network/interfaces)
    names=$(pve_declared_names "$orig")
    tmp=$(mktemp)
    pve_assign_bridges
    {
        cat "$orig"
        for c in "${P_NICS[@]}"; do
            ifc=${P_IF[$c]}
            mtu=$(pn "$c" mtu)
            br=${PVE_BR[$c]}
            printf '\n'
            if ! grep -qxF "$ifc" <<<"$names"; then
                printf 'iface %s inet manual\n' "$ifc"
                [[ -z $mtu ]] || printf '\tmtu %s\n' "$mtu"
                printf '\n'
            fi
            printf 'auto %s\n' "$br"
            if [[ $(pn "$c" method) == static ]]; then
                a=$(vmt_list_first "$(pn "$c" address)")
                printf 'iface %s inet static\n\taddress %s\n' "$br" "$a"
            else
                printf 'iface %s inet manual\n' "$br"
            fi
            printf '\tbridge-ports %s\n\tbridge-stp off\n\tbridge-fd 0\n' "$ifc"
            [[ -z $mtu ]] || printf '\tmtu %s\n' "$mtu"
            printf '%s%s\n' "$PVE_MARK_PREFIX" "$c"
        done
    } > "$tmp"
    vmt_overwrite "$tmp" /etc/network/interfaces
}

os_net_desc() {
    local c out=""
    for c in "${P_NICS[@]}"; do
        out+="${out:+, }${PVE_BR[$c]:-vmbr?}(포트 ${P_IF[$c]})"
    done
    printf '/etc/network/interfaces%s' "${out:+의 $out}"
}

# 1단계 끝: 2단계로 넘길 값을 남긴다. 완료 기록은 2단계가 남긴다
os_reid_complete() {
    mkdir -p "$VMT_STATE"
    {
        printf 'PVE_NODE=%q\n'     "$P_NODE"
        printf 'PVE_OLD_HOST=%q\n' "$VMT_TPL_HOST"
        printf 'PVE_OLD_IP=%q\n'   "${VMT_TPL_CIDR%/*}"
        printf 'PVE_NEW_HOST=%q\n' "$NEW_HOST"
        printf 'PVE_NEW_FQDN=%q\n' "$NEW_FQDN"
        printf 'PVE_NEW_CIDR=%q\n' "$NEW_CIDR"
        printf 'PVE_MGMT_IF=%q\n'  "${P_IF[$P_PRIMARY_NIC]}"
        printf 'PVE_MGMT_BR=%q\n'  "${PVE_BR[$P_PRIMARY_NIC]}"
    } > "$PVE_STAGE"
    vmt_reid_summary
    vmt_say "다음 순서: reboot, 그다음 $PROG --finish"
}

os_reid_stage2() {
    pve_reid_finish
}

pve_reid_finish() {
    vmt_require_root
    os_require
    vmt_require_ip
    [[ ! -e $VMT_REID_STAMP ]] || vmt_die "이 VM에서 이미 실행했다: $(<"$VMT_REID_STAMP")"
    [[ -f $PVE_STAGE ]] || vmt_die "1단계 기록($PVE_STAGE)이 없다. 먼저 1단계($PROG)를 실행한다"
    vmt_template_env_load
    PVE_OLD_IP=""
    PVE_NEW_FQDN=""
    # shellcheck source=/dev/null
    . "$PVE_STAGE"
    local k
    for k in PVE_NODE PVE_OLD_HOST PVE_NEW_HOST PVE_NEW_CIDR PVE_MGMT_IF PVE_MGMT_BR; do
        [[ -n ${!k:-} ]] || vmt_die "1단계 기록에 $k 값이 없다: $PVE_STAGE"
    done

    local cur
    cur=$(hostname -s)
    [[ $cur == "$PVE_NEW_HOST" ]] \
        || vmt_die "실행 중인 호스트명($cur)이 1단계 값($PVE_NEW_HOST)과 다르다. 재부팅했는지 확인한다"
    # /etc/pve/local은 현재 노드 디렉터리를 가리키는 링크다. pmxcfs가 새 이름으로 올라왔는지 본다
    [[ $(readlink /etc/pve/local) == *"nodes/$PVE_NEW_HOST" ]] \
        || vmt_die "/etc/pve/local이 nodes/$PVE_NEW_HOST를 가리키지 않는다. /etc/hosts와 호스트명을 다시 본다"
    # 새 노드 인증서에는 노드 IP가 들어간다. 관리망 브리지에 새 IP가 올라온 뒤에 발급한다
    [[ $(vmt_iface_cidr "$PVE_MGMT_BR") == "$PVE_NEW_CIDR" ]] \
        || vmt_die "$PVE_MGMT_BR에 $PVE_NEW_CIDR가 없다. NIC($PVE_MGMT_IF)와 /etc/network/interfaces를 확인한다(ip -br addr)"

    # 템플릿에서 물려받은 root SSH 키 쌍을 폐기한다.
    # authorized_keys에서는 그 공개키 줄만 빼고, 템플릿에 미리 넣어 둔 사용자 키는 남긴다
    local pub body tmp
    for pub in /root/.ssh/id_*.pub; do
        [[ -e $pub ]] || continue
        body=$(awk '{print $2}' "$pub")
        if [[ -n $body && -f /etc/pve/priv/authorized_keys ]]; then
            tmp=$(mktemp)
            grep -vF -- "$body" /etc/pve/priv/authorized_keys > "$tmp" || true
            cat "$tmp" > /etc/pve/priv/authorized_keys   # pmxcfs 파일은 덮어쓰기로 갱신한다
            rm -f "$tmp"
        fi
        rm -f "$pub" "${pub%.pub}"
    done

    # 노드 간 SSH에 쓰는 known_hosts에서 템플릿 항목(옛 노드 이름, 옛 NAT 주소)을 뺀다
    if [[ -f /etc/pve/priv/known_hosts ]]; then
        tmp=$(mktemp)
        awk -v h="$PVE_OLD_HOST" -v ip="$PVE_OLD_IP" '
            { n = split($1, a, ","); for (i = 1; i <= n; i++) if (a[i] == h || (ip != "" && a[i] == ip)) next; print }' \
            /etc/pve/priv/known_hosts > "$tmp"
        cat "$tmp" > /etc/pve/priv/known_hosts
        rm -f "$tmp"
    fi

    # 템플릿에서 물려받은 클러스터 CA, 티켓 서명 키(authkey), 부팅 때 옛 CA로 발급된 노드 인증서를 지운다.
    # updatecerts는 없는 파일을 새로 만들고, --force로 노드 인증서를 새 CA로 다시 발급한다
    rm -f /etc/pve/pve-root-ca.pem /etc/pve/priv/pve-root-ca.key \
          /etc/pve/authkey.pub /etc/pve/priv/authkey.key \
          "/etc/pve/nodes/$PVE_NEW_HOST/pve-ssl.pem" "/etc/pve/nodes/$PVE_NEW_HOST/pve-ssl.key"
    rm -rf "/etc/pve/nodes/${PVE_OLD_HOST:?}"
    # 옛 노드 이름으로 쌓인 통계(RRD) 파일
    if [[ -d /var/lib/rrdcached/db ]]; then
        find /var/lib/rrdcached/db -mindepth 2 -maxdepth 2 -name "$PVE_OLD_HOST" -exec rm -rf {} +
    fi

    pvecm updatecerts --force
    systemctl restart pvedaemon pveproxy

    NEW_HOST=$PVE_NEW_HOST
    NEW_FQDN=$PVE_NEW_FQDN
    P_NODE=$PVE_NODE
    vmt_reid_stamp
    rm -f "$PVE_STAGE"

    vmt_say "== vmt-reid 2단계 결과 =="
    vmt_say "노드 목록 : $(ls /etc/pve/nodes)"
    vmt_say "노드 인증서:"
    openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -subject -ext subjectAltName 2>/dev/null \
        || vmt_warn "노드 인증서를 읽지 못했다"
    vmt_say "CA 지문   : $(openssl x509 -in /etc/pve/pve-root-ca.pem -noout -fingerprint -sha256 2>/dev/null || echo 확인 실패)"
    vmt_say "authkey   : $(ls /etc/pve/authkey.pub /etc/pve/priv/authkey.key 2>/dev/null | tr '\n' ' ')"
    vmt_say "root 키   : $(ls /root/.ssh/id_* 2>/dev/null | tr '\n' ' ')"
    vmt_say "확인: 브라우저로 https://${PVE_NEW_CIDR%/*}:8006 에 로그인되는지 본다"
}

vmt_reid_main "$@"
