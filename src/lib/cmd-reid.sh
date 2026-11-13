# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-reid: 복제본 재식별과 노드 구성 적용
#
# 노드를 고르는 방법은 세 가지다.
#   인자 없이 실행          메뉴에서 노드 목록의 노드를 고르거나 새로 만든다
#   --node, --config        노드 목록이나 구성 파일의 노드를 바로 적용한다
#   <이름> <IP/접두>        NIC 하나를 고정 주소로 설정하는 노드를 즉석에서 만든다
# 적용 순서: 호스트명과 /etc/hosts → NIC 설정 → 추가 디스크 → 루트 확장
#            → machine-id, SSH 호스트 키, DHCP 식별 정보 → 기록
# ─────────────────────────────────────────────────────────────────────────────

REID_NODE=""

vmt_reid_usage() {
    cat <<EOF
사용법:
  sudo $0                                    메뉴에서 노드를 골라 적용한다
  sudo $0 --node <노드> [--config <파일>]    노드 목록의 노드를 적용한다
  sudo $0 --config <파일>                    노드가 하나뿐인 구성 파일을 적용한다
  sudo $0 [--iface <인터페이스>] <새 FQDN 또는 호스트명> <새 IP/접두>
                                             NIC 하나만 고정 주소로 설정한다
   예) sudo $0 --node web-01
       sudo $0 node-01.lab.internal 192.168.56.11/24

복제본에서 한 번 실행한다. 노드 구성대로 호스트명, /etc/hosts, NIC 설정, 추가 디스크,
루트 디스크 확장을 적용하고 machine-id, SSH 호스트 키, DHCP 클라이언트 식별 정보를 새로 만든다.
끝나면 재부팅한다. 새 IP를 다른 VM이 쓰고 있지 않은지는 호스트에서 먼저 확인한다.

노드 목록 기본 위치: $VMT_NODES_CONF (템플릿에서 vmt-nodes로 만든다)
호스트명만 주면 노드 구성의 domain이나 템플릿의 도메인을 붙인다.

  --check      바꾸지 않고 적용 계획만 출력한다
  --iface IF   (호스트명·IP로 실행할 때) NIC를 직접 지정한다. 후보가 둘 이상일 때 쓴다
  --version    버전을 출력한다
EOF
}

# 호스트명·IP 인자로 노드 하나를 만든다. NIC 하나(mgmt)를 고정 주소로 둔다
vmt_reid_quick_node() {  # 이름, IP/접두, 인터페이스(빈 값이면 auto)
    local name=$1 cidr=$2 host
    vmt_valid_cidr "$cidr" \
        || vmt_die "IP/접두 형식이 맞지 않다: $cidr (예: 192.168.56.11/24)"
    vmt_usable_host_cidr "$cidr" \
        || vmt_die "호스트 주소로 쓸 수 없는 IP다: $cidr (네트워크 주소, 브로드캐스트 주소, 루프백, 멀티캐스트)"
    host=${name%%.*}
    vmt_valid_hostname "$host" \
        || vmt_die "호스트명 형식이 맞지 않다: $host (소문자로 시작, 소문자·숫자·하이픈, 63자 이하)"
    [[ $name != *.* ]] || vmt_valid_fqdn "$name" \
        || vmt_die "FQDN 형식이 맞지 않다: $name (예: node-01.lab.internal)"
    [[ -z $3 ]] || [[ $3 =~ ^[A-Za-z0-9._-]{1,15}$ ]] || vmt_die "인터페이스 이름이 맞지 않다: $3"
    vmt_cfg_reset
    CFG_NODES=$host
    CFG[node.$host.hostname]=$name
    CFG_NICS[$host]=mgmt
    CFG_DISKS[$host]=""
    CFG[nic.$host.mgmt.interface]=${3:-auto}
    CFG[nic.$host.mgmt.address]=$cidr
    VMT_LEGACY=1
    REID_NODE=$host
}

# 복제본인지, 적용할 수 있는 상태인지 확인한다. 아무것도 바꾸지 않는다
vmt_reid_preflight() {
    [[ ! -e $VMT_REID_STAMP ]] || vmt_die "이 VM에서 이미 실행했다: $(<"$VMT_REID_STAMP")"
    vmt_template_env_load

    # 템플릿 VM에서 실행하는 실수를 막는다.
    # 복제 기능(VBoxManage clonevm, New-VM)은 MAC을 새로 만들므로 템플릿 MAC이 보이면 템플릿 VM이다.
    local hit
    if hit=$(vmt_iface_with_mac "$VMT_TPL_MAC"); then
        vmt_die "템플릿 VM이다($hit의 MAC $VMT_TPL_MAC이 템플릿 기록과 같다). 복제본에서 실행한다. 노드 목록은 템플릿에서 vmt-nodes로 고친다"
    fi
    vmt_require_machine_id_file

    # NAT 인터페이스는 템플릿과 같은 이름으로 DHCP 주소와 기본 경로를 받아 있어야 한다.
    # 아니면 NIC 순서가 바뀌었거나 첫 번째 어댑터가 NAT가 아니다. 이 상태로 NIC를 고르면 NAT NIC를 고를 수 있다
    [[ -e /sys/class/net/$VMT_TPL_IFACE ]] \
        || vmt_die "템플릿의 NAT 인터페이스 $VMT_TPL_IFACE가 없다. 복제본의 첫 번째 어댑터가 NAT인지 호스트에서 확인한다"
    local -a defs
    local d natdef=0
    mapfile -t defs < <(vmt_default_ifaces)
    for d in "${defs[@]}"; do
        [[ $d == "$VMT_TPL_IFACE" ]] && natdef=1
    done
    (( natdef )) \
        || vmt_die "NAT 인터페이스 $VMT_TPL_IFACE에 기본 경로가 없다. DHCP 주소를 받았는지(ip -4 route), 첫 번째 어댑터가 NAT인지 확인한다"
}

vmt_reid_main() {
    local node="" file="" check=0 finish=0 iface="" n menu=0
    local -a pos=()
    while (( $# )); do
        case $1 in
            -h|--help) vmt_reid_usage; exit 0 ;;
            --version) printf '%s %s\n' "$PROG" "$VMT_VERSION"; exit 0 ;;
            --check)   check=1 ;;
            --finish)  finish=1 ;;
            --node|--config|--iface)
                [[ $# -ge 2 ]] || { vmt_reid_usage >&2; exit 2; }
                case $1 in
                    --node)   node=$2 ;;
                    --config) file=$2 ;;
                    --iface)  iface=$2 ;;
                esac
                shift
                ;;
            --node=*)   node=${1#*=} ;;
            --config=*) file=${1#*=} ;;
            --iface=*)  iface=${1#*=} ;;
            -*) vmt_reid_usage >&2; exit 2 ;;
            *)  pos+=("$1") ;;
        esac
        shift
    done
    if (( finish )); then
        [[ $check == 0 && -z $node$file$iface && ${#pos[@]} -eq 0 ]] || { vmt_reid_usage >&2; exit 2; }
        os_reid_stage2
        return 0
    fi
    # 인자 조합: 호스트명·IP / --node·--config / 없음(메뉴)
    if (( ${#pos[@]} )); then
        [[ ${#pos[@]} -eq 2 && -z $node$file ]] || { vmt_reid_usage >&2; exit 2; }
    else
        [[ -z $iface ]] || { vmt_reid_usage >&2; exit 2; }
        if [[ -z $node$file ]] && (( check )); then
            vmt_reid_usage >&2
            exit 2
        fi
    fi

    vmt_require_root
    os_require
    vmt_require_ip
    vmt_reid_preflight

    if (( ${#pos[@]} )); then
        vmt_reid_quick_node "${pos[0]}" "${pos[1]}" "$iface"
    elif [[ -n $node$file ]]; then
        file=${file:-$VMT_NODES_CONF}
        [[ -f $file ]] || vmt_die "노드 목록이 없다: $file. 템플릿에서 vmt-nodes로 만들거나 --config로 파일을 준다"
        vmt_cfg_load_checked "$file"
        if [[ -z $node ]]; then
            read -r -a pos <<<"$CFG_NODES"
            (( ${#pos[@]} == 1 )) || vmt_die "$file에 노드가 ${#pos[@]}개 있다(${CFG_NODES:-없음}). --node로 고른다"
            node=${pos[0]}
        fi
        n=" $CFG_NODES "
        [[ $n == *" $node "* ]] || vmt_die "노드가 없다: $node. $file의 노드: ${CFG_NODES:-없음}"
        REID_NODE=$node
    else
        vmt_reid_menu
        menu=1
    fi

    vmt_plan_build "$REID_NODE"
    # 메뉴에서는 적용을 고르기 전에 계획을 이미 보여 줬다
    (( menu )) || vmt_plan_print
    if (( check )); then
        vmt_say "--check: 아무것도 바꾸지 않았다"
        return 0
    fi
    vmt_reid_apply
}

vmt_reid_apply() {
    vmt_reid_rename "$VMT_RENAME_RUNTIME"
    os_write_network
    os_after_net_edit
    vmt_storage_apply
    vmt_root_grow_apply
    vmt_regen_machine_id
    os_ssh_hostkeys
    os_reset_dhcp
    os_reid_finish
    vmt_node_record
    os_reid_complete
}

# 호스트명, /etc/hosts, 메일 이름을 바꾼다.
# 인자: 실행 중인 호스트명도 바로 바꿀지(1) 재부팅 때 반영할지(0)
vmt_reid_rename() {
    local runtime=$1 tmp

    vmt_backup_once /etc/hostname /etc/hosts /etc/mailname /etc/postfix/main.cf

    printf '%s\n' "$NEW_HOST" > /etc/hostname
    # 옛 이름은 /etc/hosts에서 빠지므로, 실행 중인 이름을 그대로 두면 재부팅 전까지 sudo가 경고를 낸다
    if (( runtime )); then
        hostname "$NEW_HOST"
    fi

    tmp=$(mktemp)
    vmt_hosts_render "$(vmt_orig /etc/hosts)" "$VMT_TPL_HOST" "$VMT_TPL_FQDN" \
        "$NEW_IP" "$NEW_HOST" "$NEW_HOSTS_LINE" > "$tmp"
    vmt_overwrite "$tmp" /etc/hosts
    # 새 이름은 새 IP에만 있어야 하고, 템플릿 이름은 남으면 안 된다
    awk -v h="$NEW_HOST" -v f="$NEW_FQDN" -v ip="$NEW_IP" -v oh="$VMT_TPL_HOST" -v of="$VMT_TPL_FQDN" '
        /^[[:space:]]*(#|$)/ { next }
        {
            for (i = 2; i <= NF && $i !~ /^#/; i++) {
                if ($i == h) { n++; if ($1 != ip) bad = 1 }
                if (f != "" && $i == f && $1 != ip) bad = 1
                if ($i == oh || (of != "" && $i == of)) bad = 1
            }
        }
        END { exit !(n >= 1 && !bad) }' /etc/hosts \
        || vmt_die "/etc/hosts를 고친 결과가 맞지 않다(새 이름은 새 IP에만, 템플릿 이름은 없어야 한다). 원본: $(vmt_orig /etc/hosts)"

    if [[ -f /etc/mailname ]]; then
        printf '%s\n' "${NEW_FQDN:-$NEW_HOST}" > /etc/mailname
    fi
    if [[ -f /etc/postfix/main.cf ]]; then
        tmp=$(mktemp)
        if [[ -n $VMT_TPL_FQDN ]]; then
            sed "s/$(vmt_re_escape "$VMT_TPL_FQDN")/${NEW_FQDN:-$NEW_HOST}/g" "$(vmt_orig /etc/postfix/main.cf)" > "$tmp"
        else
            cat "$(vmt_orig /etc/postfix/main.cf)" > "$tmp"
        fi
        vmt_overwrite "$tmp" /etc/postfix/main.cf
    fi
}

# 적용한 노드 구성을 /etc/vmt/node.conf에 남긴다. [defaults] 값을 합치고 NIC 대응을 주석으로 적는다
vmt_node_record() {
    local tmp c
    tmp=$(mktemp)
    {
        printf '# vmt-reid %s가 %s에 적용한 노드 구성이다. 기록용이며 다시 적용하지 않는다\n' "$VMT_VERSION" "$(date -Is)"
        for c in "${P_NICS[@]}"; do
            printf '# [nic %s] -> %s (MAC %s)\n' "$c" "${P_IF[$c]}" "${P_MAC[$c]}"
        done
        vmt_cfg_render "$P_NODE"
    } > "$tmp"
    vmt_install_file "$tmp" "$VMT_NODE_CONF" 644
}

vmt_reid_stamp() {
    mkdir -p "$VMT_ETC"
    printf '%s %s -> %s node %s vmt %s\n' "$(date -Is)" \
        "$VMT_TPL_HOST" "${NEW_FQDN:-$NEW_HOST}" "$P_NODE" "$VMT_VERSION" > "$VMT_REID_STAMP"
}

vmt_reid_summary() {
    local c dev v n
    vmt_say "== vmt-reid 결과: $VMT_TPL_HOST -> ${NEW_FQDN:-$NEW_HOST} =="
    vmt_say "호스트명      : $(</etc/hostname)"
    vmt_say "/etc/hosts    : $(awk -v h="$NEW_HOST" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == h) { print; next } }' /etc/hosts)"
    for c in "${P_NICS[@]}"; do
        n=$(pn "$c" address)
        vmt_say "NIC $c : ${P_IF[$c]} (MAC ${P_MAC[$c]}) $(pn "$c" method)${n:+ $n}"
    done
    vmt_say "NIC 설정 파일 : $(os_net_desc)"
    for dev in "${P_DEVS[@]}"; do
        for v in ${P_DEV_VOLS[$dev]}; do
            vmt_say "디스크 $v : $dev $(pd "$v" fs) $(pd "$v" mount) ${P_UUID[$v]:+UUID=${P_UUID[$v]}}"
        done
    done
    vmt_say "루트 확장     : $R_DESC"
    vmt_say "machine-id    : $VMT_OLD_MID -> $VMT_NEW_MID"
    if compgen -G '/etc/ssh/ssh_host_ed25519_key.pub' >/dev/null; then
        vmt_say "SSH 호스트 키 : $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || echo 확인 실패)"
    else
        vmt_say "SSH 호스트 키 : 재부팅 때 생성"
    fi
    vmt_say "노드 구성 기록: $VMT_NODE_CONF"
}
