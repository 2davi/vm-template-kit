# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# 적용 계획: 노드 구성을 이 VM의 하드웨어에 맞춘다
#
# vmt_plan_build <노드>는 아무것도 바꾸지 않는다. 맞지 않는 점이 있으면 vmt_die로 멈춘다.
# 결과는 아래 전역 변수에 둔다. OS별 설정 파일 작성 함수(os_write_network)가 이 값을 읽는다.
#   P_NODE                     적용할 노드 이름
#   NEW_HOST, NEW_FQDN         새 호스트명과 FQDN(도메인이 없으면 빈 값)
#   NEW_IP, NEW_CIDR           /etc/hosts에 쓸 IP와 그 IP/접두. 첫 고정 주소를 쓰고, 없으면 127.0.1.1
#   NEW_HOSTS_LINE             /etc/hosts에 넣을 줄
#   P_NICS                     NIC 구역 이름 배열(파일 순서)
#   P_IF[NIC], P_MAC[NIC]      NIC 구역에 맞춘 인터페이스 이름과 MAC
#   P_PRIMARY_NIC              NEW_CIDR를 가진 NIC 구역(없으면 빈 값)
#   P_DNS_NIC                  DNS 서버와 검색 도메인을 붙일 NIC 구역(없으면 빈 값)
#   P_DEVS                     추가 디스크 이름 배열, P_DEV_VOLS[디스크]는 그 디스크의 볼륨 목록
#   P_DEV_DONE[디스크]         이전 실행에서 이미 만든 디스크면 1. P_UUID[볼륨]에 그때 만든 UUID가 있다
#   R_*                        루트 디스크 확장(plan_root 참고)
# ─────────────────────────────────────────────────────────────────────────────

VMT_DISK_STATE=$VMT_STATE/disk   # 추가 디스크를 만든 기록. 다시 실행할 때 같은 구성인지 대조한다
VMT_DHCP_METRIC=2000             # vmt-reid가 설정한 DHCP NIC의 경로 metric. NAT 쪽 기본 경로보다 뒤로 둔다
VMT_GW_METRIC=50                 # gateway를 적은 NIC의 기본 경로 metric. NAT 쪽 기본 경로보다 앞에 둔다
VMT_LEGACY=0                     # 1이면 호스트명·IP 인자로 실행한 경우다(메시지에 --iface를 안내한다)

P_NODE=""
P_NICS=()
P_DEVS=()
P_PRIMARY_NIC=""
P_DNS_NIC=""
declare -A P_IF=() P_MAC=() P_DEV_VOLS=() P_DEV_DONE=() P_DEV_MIB=() P_UUID=()

pn() { cfg_nic "$P_NODE" "$1" "$2"; }    # 적용할 노드의 NIC 값
pd() { cfg_disk "$P_NODE" "$1" "$2"; }   # 적용할 노드의 디스크 값

vmt_list_first() {
    local -a a
    mapfile -t a < <(vmt_list "$1")
    printf '%s' "${a[0]-}"
}

# 이 VM의 NIC 목록: 이름(MAC, 주소)
vmt_nic_inventory() {
    local n a out=""
    while read -r n; do
        [[ -n $n ]] || continue
        a=$(vmt_iface_cidr "$n")
        [[ $n == "${VMT_TPL_IFACE:-}" ]] && a="NAT${a:+ $a}"
        out+="${out:+, }$n($(vmt_mac_of "$n")${a:+, $a})"
    done < <(vmt_physical_nics)
    printf '%s' "${out:-없음}"
}

# 이 VM의 디스크 목록: 이름(크기, 상태). 루프, 램, 광학, 장치 매퍼 장치는 뺀다
vmt_disk_inventory() {
    local d n out="" st
    for d in /sys/block/*; do
        n=${d##*/}
        [[ -e $d/size ]] || continue
        case $n in loop*|ram*|sr*|dm-*|zram*|md*|fd*) continue ;; esac
        if [[ -f $VMT_DISK_STATE/$n ]]; then st="vmt가 만듦"
        elif compgen -G "$d/$n*" >/dev/null; then st="파티션 있음"
        else st="파티션 없음"
        fi
        out+="${out:+, }$n($(vmt_human_mib $(( $(<"$d/size") / 2048 ))), $st)"
    done
    printf '%s' "${out:-없음}"
}

# ── 계획 만들기 ─────────────────────────────────────────────────────────────
vmt_plan_build() {  # 노드
    P_NODE=$1
    [[ " $CFG_NODES " == *" $P_NODE "* ]] || vmt_die "노드가 없다: $P_NODE. 있는 노드: ${CFG_NODES:-없음}"
    plan_names
    plan_nics
    plan_addresses
    plan_disks
    plan_root
    local bad
    bad=$(vmt_hosts_conflicts "$(vmt_orig /etc/hosts)")
    [[ -z $bad ]] \
        || vmt_die "/etc/hosts의 다음 줄이 새 이름, 새 IP와 맞지 않다. 고친 뒤 다시 실행한다: $bad"
    os_reid_checks
}

plan_names() {
    local h d
    h=$(cfg_hostname "$P_NODE")
    if [[ $h == *.* ]]; then
        NEW_HOST=${h%%.*}
        NEW_FQDN=$h
    else
        NEW_HOST=$h
        d=$(cfg_node "$P_NODE" domain)
        # 도메인을 적지 않았으면 템플릿 FQDN의 도메인을 쓴다
        if [[ -z $d && $VMT_TPL_FQDN == *.* ]]; then d=${VMT_TPL_FQDN#*.}; fi
        NEW_FQDN=${d:+$h.$d}
    fi
    [[ $NEW_HOST != "$VMT_TPL_HOST" ]] || vmt_die "템플릿 호스트명과 같다: $NEW_HOST"
}

# auto NIC를 찾지 못했을 때 메시지의 주어
plan_auto_subject() {  # NIC 구역
    if (( VMT_LEGACY )); then printf '관리망 NIC'; else printf '[nic %s]에 쓸 NIC' "$1"; fi
}

plan_iface_hint() {
    if (( VMT_LEGACY )); then printf -- '--iface로 지정한다'; else printf 'interface에 이름(예: enp0s8)이나 mac:<MAC>을 적는다'; fi
}

plan_check_nic() {  # NIC 구역, 인터페이스, 기본 경로를 가진 인터페이스...
    local c=$1 ifc=$2 d
    shift 2
    [[ $ifc != "$VMT_TPL_IFACE" ]] \
        || vmt_die "[nic $c] $ifc는 템플릿의 NAT 인터페이스다. NAT NIC는 템플릿 설정을 그대로 쓰므로 다른 NIC를 적는다"
    vmt_is_physical "$ifc" || vmt_die "[nic $c] $ifc는 물리 NIC가 아니다(브리지, 본드, VLAN)"
    [[ ! -e /sys/class/net/$ifc/master ]] || vmt_die "[nic $c] $ifc는 브리지나 본드의 포트다"
    for d in "$@"; do
        [[ $ifc == "$d" ]] && vmt_warn "[nic $c] $ifc에 기본 경로가 있다. NAT 쪽 NIC가 아닌지 호스트에서 어댑터 구성을 확인한다"
    done
    return 0
}

# NIC 구역을 인터페이스에 맞춘다. 이름과 MAC으로 적은 NIC를 먼저 정하고, auto는 남은 후보가 하나일 때만 정한다.
# 후보는 물리 NIC 가운데 템플릿의 NAT 인터페이스도, 기본 경로를 가진 인터페이스도 아닌 NIC다
plan_nics() {
    local c spec ifc n d isdef subj list=""
    local -a defs autos=() cands=() skipped=()
    local -A used=()
    P_NICS=()
    P_IF=()
    P_MAC=()
    read -r -a P_NICS <<<"${CFG_NICS[$P_NODE]-}"
    mapfile -t defs < <(vmt_default_ifaces)
    for c in "${P_NICS[@]}"; do
        spec=$(pn "$c" interface)
        case $spec in
            auto)
                autos+=("$c")
                continue
                ;;
            mac:*)
                ifc=$(vmt_iface_with_mac "${spec#mac:}") \
                    || vmt_die "[nic $c] MAC ${spec#mac:}을 가진 NIC가 없다. 이 VM의 NIC: $(vmt_nic_inventory)"
                ;;
            *)
                ifc=$spec
                [[ -e /sys/class/net/$ifc ]] || vmt_die "[nic $c] 인터페이스가 없다: $ifc. 이 VM의 NIC: $(vmt_nic_inventory)"
                ;;
        esac
        plan_check_nic "$c" "$ifc" "${defs[@]}"
        [[ -z ${used[$ifc]-} ]] || vmt_die "[nic $c]와 [nic ${used[$ifc]}]가 같은 NIC($ifc)를 가리킨다"
        used[$ifc]=$c
        P_IF[$c]=$ifc
    done
    while read -r n; do
        [[ -n $n && $n != "$VMT_TPL_IFACE" && -z ${used[$n]-} ]] || continue
        isdef=0
        for d in "${defs[@]}"; do
            [[ $n == "$d" ]] && isdef=1
        done
        if (( isdef )); then skipped+=("$n"); else cands+=("$n"); fi
    done < <(vmt_physical_nics)
    if (( ${#autos[@]} )); then
        c=${autos[0]}
        subj=$(plan_auto_subject "$c")
        if (( ${#cands[@]} == 0 )); then
            (( ${#skipped[@]} == 0 )) \
                || vmt_die "$subj 후보가 없다. 기본 경로를 가진 NIC(${skipped[*]})는 NAT 쪽으로 보고 뺐다. 그 NIC가 맞으면 $(plan_iface_hint)"
            vmt_die "$subj 후보가 없다. 호스트에서 복제본에 어댑터(VirtualBox 호스트 전용 어댑터, Hyper-V 내부 스위치)를 붙였는지 확인한다"
        fi
        if (( ${#cands[@]} > 1 )); then
            for n in "${cands[@]}"; do list+="${list:+, }$n($(vmt_mac_of "$n"))"; done
            vmt_die "$subj 후보가 여럿이다: $list. $(plan_iface_hint)"
        fi
        P_IF[$c]=${cands[0]}
        cands=()
    fi
    for c in "${P_NICS[@]}"; do
        P_MAC[$c]=$(vmt_mac_of "${P_IF[$c]}")
        [[ -n ${P_MAC[$c]} ]] || vmt_die "${P_IF[$c]}의 MAC 주소를 읽지 못했다"
    done
    if (( ${#cands[@]} )); then
        vmt_warn "노드 구성에 없는 NIC가 있다: ${cands[*]}. vmt-reid는 이 NIC의 설정을 만들지 않는다"
    fi
    return 0
}

# /etc/hosts에 쓸 주소, DNS를 붙일 NIC, NAT 대역과 겹치는지 검사
plan_addresses() {
    local c m a nat cur first_dhcp=""
    NEW_CIDR=""
    P_PRIMARY_NIC=""
    P_DNS_NIC=""
    nat=$(vmt_iface_cidr "$VMT_TPL_IFACE")
    nat=${nat:-$VMT_TPL_CIDR}
    for c in "${P_NICS[@]}"; do
        m=$(pn "$c" method)
        if [[ $m == static ]]; then
            if [[ -z $P_PRIMARY_NIC ]]; then
                P_PRIMARY_NIC=$c
                NEW_CIDR=$(vmt_list_first "$(pn "$c" address)")
            fi
            while read -r a; do
                if [[ -n $nat ]] && vmt_cidr_overlap "$nat" "$a"; then
                    vmt_die "[nic $c] $a가 NAT 쪽 대역($VMT_TPL_IFACE $nat)과 겹친다. 다른 대역의 주소를 쓴다"
                fi
            done < <(vmt_list "$(pn "$c" address)")
        elif [[ $m == dhcp && -z $first_dhcp ]]; then
            first_dhcp=$c
        fi
        cur=$(vmt_iface_cidr "${P_IF[$c]}")
        if [[ -n $cur ]]; then
            vmt_warn "${P_IF[$c]}([nic $c])에 이미 주소($cur)가 있다. 재부팅 뒤 노드 구성의 주소만 남는지 확인한다(ip -br addr)"
        fi
    done
    P_DNS_NIC=${P_PRIMARY_NIC:-$first_dhcp}
    if [[ -n $NEW_CIDR ]]; then NEW_IP=${NEW_CIDR%/*}; else NEW_IP=127.0.1.1; fi
    if [[ -n $NEW_FQDN ]]; then
        NEW_HOSTS_LINE="$NEW_IP"$'\t'"$NEW_FQDN"$'\t'"$NEW_HOST"
    else
        NEW_HOSTS_LINE="$NEW_IP"$'\t'"$NEW_HOST"
    fi
}

# ── 추가 디스크 ─────────────────────────────────────────────────────────────
plan_disks() {
    local d dev
    P_DEVS=()
    P_DEV_VOLS=()
    P_DEV_DONE=()
    P_DEV_MIB=()
    P_UUID=()
    for d in ${CFG_DISKS[$P_NODE]-}; do
        dev=$(pd "$d" device)
        if [[ -z ${P_DEV_VOLS[$dev]+x} ]]; then
            P_DEVS+=("$dev")
            P_DEV_VOLS[$dev]=""
        fi
        P_DEV_VOLS[$dev]+="${P_DEV_VOLS[$dev]:+ }$d"
    done
    for dev in "${P_DEVS[@]}"; do
        plan_disk "$dev"
    done
    (( ${#P_DEVS[@]} == 0 )) || plan_disk_tools
}

# 디스크 기록과 대조할 구성. 마운트 경로와 옵션은 빼고, 다시 만들어야 바뀌는 값만 적는다
plan_dev_text() {  # 디스크
    local v
    for v in ${P_DEV_VOLS[$1]}; do
        printf 'plan %s size=%s fs=%s lvm=%s vg=%s label=%s\n' "$v" "$(pd "$v" size)" "$(pd "$v" fs)" \
            "$(pd "$v" lvm)" "$(pd "$v" vg)" "${CFG[disk.$P_NODE.$v.label]-}"
    done
}

plan_disk() {  # 디스크
    local dev=$1 sys=/sys/block/$1 first v x mib want="" rc sig state m fixed=0 unsized="" avail lvm
    local -a vols
    read -r -a vols <<<"${P_DEV_VOLS[$dev]}"
    first=${vols[0]}
    [[ -e $sys/size ]] || vmt_die "[disk $first] 디스크가 없다: $dev. 이 VM의 디스크: $(vmt_disk_inventory)"
    [[ $(<"$sys/ro") == 0 ]] || vmt_die "[disk $first] $dev는 읽기 전용이다"
    mib=$(( $(<"$sys/size") / 2048 ))
    P_DEV_MIB[$dev]=$mib

    # disk_size: 디스크를 잘못 가리키지 않았는지 크기로 확인한다(±2%)
    for v in "${vols[@]}"; do
        x=$(pd "$v" disk_size)
        [[ -z $x ]] || want=$x
    done
    if [[ -n $want ]]; then
        x=$(vmt_size_mib "$want")
        (( mib * 100 >= x * 98 && mib * 100 <= x * 102 )) \
            || vmt_die "[disk $first] $dev 크기($(vmt_human_mib "$mib"))가 disk_size($want)와 다르다. 다른 디스크를 가리키고 있지 않은지 확인한다. 이 VM의 디스크: $(vmt_disk_inventory)"
    fi

    state=$VMT_DISK_STATE/$dev
    if [[ -f $state ]]; then
        # 이전 실행에서 만든 디스크다. 같은 구성이면 다시 만들지 않고 그때의 UUID를 쓴다
        [[ $(grep '^plan ' "$state") == "$(plan_dev_text "$dev")" ]] \
            || vmt_die "[disk $first] $dev는 이 VM에서 다른 구성으로 이미 만들었다($state). 노드 구성을 그때 값으로 되돌리거나, 디스크를 비우고(wipefs -a /dev/$dev) 기록 파일을 지운다"
        P_DEV_DONE[$dev]=1
        while read -r _ v x; do
            P_UUID[$v]=$x
        done < <(grep '^uuid ' "$state")
    else
        ! compgen -G "$sys/holders/*" >/dev/null \
            || vmt_die "[disk $first] $dev를 다른 장치(LVM, RAID, 암호화)가 쓰고 있다"
        ! compgen -G "$sys/$dev*" >/dev/null \
            || vmt_die "[disk $first] $dev에 파티션이 있다. vmt-reid는 빈 디스크만 나눈다. 데이터가 필요 없으면 wipefs -a /dev/$dev로 비운 뒤 다시 실행한다"
        rc=0
        sig=$(blkid -p -o export "/dev/$dev" 2>/dev/null) || rc=$?
        case $rc in
            2)  ;;
            0)  vmt_die "[disk $first] $dev가 비어 있지 않다($(printf '%s\n' "$sig" | grep -E '^(PT)?TYPE=' | paste -sd' ' -)). vmt-reid는 빈 디스크만 나눈다. 데이터가 필요 없으면 wipefs -a /dev/$dev로 비운 뒤 다시 실행한다" ;;
            *)  vmt_die "[disk $first] $dev를 blkid로 확인하지 못했다(종료 코드 $rc)" ;;
        esac
    fi

    # 크기 합계. 파티션은 앞뒤 GPT 영역 2MiB, LVM은 PV 메타데이터와 익스텐트(4MiB) 단위를 더 뺀다
    lvm=$(pd "$first" lvm)
    for v in "${vols[@]}"; do
        x=$(pd "$v" size)
        if [[ -z $x ]]; then unsized=$v; continue; fi
        x=$(vmt_size_mib "$x")
        [[ $lvm == yes ]] && x=$(( (x + 3) / 4 * 4 ))
        fixed=$(( fixed + x ))
    done
    if [[ $lvm == yes ]]; then avail=$(( mib - 8 )); else avail=$(( mib - 2 )); fi
    (( fixed <= avail )) \
        || vmt_die "[disk $first] $dev 볼륨 크기 합계($(vmt_human_mib "$fixed"))가 쓸 수 있는 크기($(vmt_human_mib "$avail"))보다 크다"
    if [[ -n $unsized ]] && (( avail - fixed < 64 )); then
        vmt_die "[disk $unsized] $dev에 남는 공간이 64M보다 작다. 앞 볼륨의 size를 줄인다"
    fi

    # 마운트 경로: 다른 파일 시스템이 마운트되어 있거나, 비어 있지 않은 디렉터리면 거부한다
    for v in "${vols[@]}"; do
        m=$(pd "$v" mount)
        [[ -n $m ]] || continue
        if mountpoint -q "$m" 2>/dev/null; then
            [[ ${P_DEV_DONE[$dev]-} == 1 ]] || vmt_die "[disk $v] $m에 이미 다른 파일 시스템이 마운트되어 있다"
        elif [[ -e $m && ! -d $m ]]; then
            vmt_die "[disk $v] 마운트 경로 $m가 디렉터리가 아니다"
        elif [[ -d $m && -n $(ls -A "$m" 2>/dev/null) ]]; then
            vmt_die "[disk $v] 마운트 경로 $m가 비어 있지 않다. 마운트하면 안의 파일이 가려진다. 다른 경로를 쓰거나 파일을 옮긴 뒤 다시 실행한다"
        fi
    done
    return 0
}

plan_disk_tools() {
    local dev v fs t vg
    local -a need=(sfdisk blkid) missing=()
    local -A seen=()
    for dev in "${P_DEVS[@]}"; do
        [[ ${P_DEV_DONE[$dev]-} == 1 ]] && continue
        for v in ${P_DEV_VOLS[$dev]}; do
            fs=$(pd "$v" fs)
            [[ $fs == none ]] || need+=("mkfs.$fs")
            [[ $(pd "$v" lvm) == yes ]] && need+=(pvcreate vgcreate lvcreate vgs)
        done
    done
    for t in "${need[@]}"; do
        [[ -z ${seen[$t]-} ]] || continue
        seen[$t]=1
        command -v "$t" >/dev/null || missing+=("$t")
    done
    (( ${#missing[@]} == 0 )) \
        || vmt_die "디스크 구성에 필요한 명령이 없다: ${missing[*]}. mkfs.xfs는 xfsprogs, LVM 명령은 lvm2 패키지에 있다. 템플릿에 설치한다"
    for dev in "${P_DEVS[@]}"; do
        [[ ${P_DEV_DONE[$dev]-} == 1 ]] && continue
        v=${P_DEV_VOLS[$dev]%% *}
        [[ $(pd "$v" lvm) == yes ]] || continue
        vg=$(pd "$v" vg)
        if vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' | grep -qxF -- "$vg"; then
            vmt_die "[disk $v] VG 이름 $vg가 이미 있다. vg에 다른 이름을 적는다"
        fi
    done
    return 0
}

# ── 루트 디스크 확장 ────────────────────────────────────────────────────────
#   R_DO          1이면 늘린다
#   R_FS          루트 파일 시스템 종류(ext4, xfs)
#   R_VG, R_LV    루트가 LVM 논리 볼륨이면 그 VG와 LV
#   R_PART        늘릴 파티션(LVM이면 PV 파티션). 없으면 빈 값
#   R_DISK        R_PART가 있는 디스크, R_PARTNUM 파티션 번호
#   R_GROW_PART   1이면 growpart로 파티션을 늘린다
#   R_DESC        계획 설명
R_DO=0
R_FS=""
R_VG=""
R_LV=""
R_PART=""
R_DISK=""
R_PARTNUM=""
R_GROW_PART=0
R_DESC=""

vmt_vg_free_mib() {  # VG
    local b
    b=$(vgs --noheadings --units b --nosuffix -o vg_free "$1" 2>/dev/null | tr -d ' ')
    [[ $b =~ ^[0-9]+$ ]] || b=0
    printf '%d' $(( b / 1024 / 1024 ))
}

plan_root() {
    local src fs rc out free=0 parent
    local -a pvs
    R_DO=0
    R_GROW_PART=0
    R_FS=""
    R_VG=""
    R_LV=""
    R_PART=""
    R_DISK=""
    R_PARTNUM=""
    if [[ $(cfg_node "$P_NODE" root_grow) != yes ]]; then
        R_DESC="하지 않는다(root_grow = no)"
        return 0
    fi
    read -r src fs < <(findmnt -nro SOURCE,FSTYPE /) || true
    src=${src%%\[*}
    case $fs in
        ext4|xfs) R_FS=$fs ;;
        *) vmt_die "root_grow: 루트 파일 시스템이 ext4나 xfs가 아니다(${fs:-알 수 없음}). root_grow = no로 둔다" ;;
    esac
    if lvs --noheadings -o vg_name,lv_name "$src" >/dev/null 2>&1; then
        read -r R_VG R_LV < <(lvs --noheadings -o vg_name,lv_name "$src")
        mapfile -t pvs < <(pvs --noheadings -o pv_name -S "vg_name=$R_VG" 2>/dev/null | tr -d ' ')
        parent=""
        (( ${#pvs[@]} != 1 )) || parent=$(lsblk -no PKNAME "${pvs[0]}" 2>/dev/null || true)
        if [[ -n $parent ]]; then
            R_PART=${pvs[0]}
        else
            vmt_warn "root_grow: VG $R_VG의 PV가 하나가 아니거나 디스크 전체다(${pvs[*]:-없음}). 파티션은 늘리지 않고 VG에 남은 공간만 쓴다"
        fi
    else
        R_PART=$src
    fi
    if [[ -n $R_PART ]]; then
        parent=$(lsblk -no PKNAME "$R_PART" 2>/dev/null || true)
        parent=${parent%%$'\n'*}
        R_PARTNUM=${R_PART##*[!0-9]}
        [[ -n $parent && -n $R_PARTNUM ]] || vmt_die "root_grow: $R_PART의 디스크와 파티션 번호를 알아내지 못했다. root_grow = no로 둔다"
        R_DISK=/dev/$parent
        command -v growpart >/dev/null \
            || vmt_die "root_grow: growpart가 없다. 템플릿에 $VMT_GROWPART_PKG 패키지를 설치하거나 root_grow = no로 둔다"
        # growpart -N: 0이면 늘릴 수 있고, 1이면 늘릴 공간이 없고, 2면 오류다
        rc=0
        out=$(growpart -N "$R_DISK" "$R_PARTNUM" 2>&1) || rc=$?
        case $rc in
            0) R_GROW_PART=1 ;;
            1) ;;
            *) vmt_die "root_grow: growpart -N $R_DISK $R_PARTNUM 실패: ${out:-출력 없음}. root_grow = no로 둔다" ;;
        esac
    fi
    [[ -z $R_VG ]] || free=$(vmt_vg_free_mib "$R_VG")
    if (( R_GROW_PART )) && [[ -n $R_VG ]]; then
        R_DESC="$R_PART 파티션을 디스크 끝까지 늘리고, $R_VG/$R_LV와 $R_FS 파일 시스템을 VG의 남은 공간 전체로 늘린다"
    elif (( R_GROW_PART )); then
        R_DESC="$R_PART 파티션과 $R_FS 파일 시스템을 디스크 끝까지 늘린다"
    elif (( free > 0 )); then
        R_DESC="VG $R_VG에 남은 $(vmt_human_mib "$free")를 $R_VG/$R_LV에 더하고 $R_FS 파일 시스템을 늘린다"
    else
        R_DESC="늘릴 공간이 없다(${R_PART:-$src}가 이미 디스크 끝까지 쓴다)"
    fi
    if (( R_GROW_PART || free > 0 )); then R_DO=1; fi
    return 0
}

# ── 계획 출력 ───────────────────────────────────────────────────────────────
vmt_plan_print() {
    local c m a x dev v sz fs mnt
    vmt_say "== 적용 계획: 노드 $P_NODE =="
    vmt_say "호스트명     ${NEW_FQDN:-$NEW_HOST} (템플릿 $VMT_TPL_HOST)"
    vmt_say "/etc/hosts   ${NEW_HOSTS_LINE//$'\t'/ }"
    if (( ${#P_NICS[@]} == 0 )); then
        vmt_say "NIC          없음(NAT NIC만 쓴다)"
    else
        vmt_say "NIC"
    fi
    for c in "${P_NICS[@]}"; do
        m=$(pn "$c" method)
        case $m in
            static) a="고정 $(vmt_list "$(pn "$c" address)" | paste -sd' ' -)" ;;
            dhcp)   a="DHCP" ;;
            off)    a="주소 없음(링크만 올린다)" ;;
        esac
        printf '  %-10s %s (%s) %s\n' "$c" "${P_IF[$c]}" "${P_MAC[$c]}" "$a"
        x=$(pn "$c" gateway)
        [[ -z $x ]] || printf '  %-10s 기본 경로 %s (metric %d, NAT보다 앞선다)\n' "" "$x" "$VMT_GW_METRIC"
        while read -r x; do
            printf '  %-10s 경로 %s\n' "" "$x"
        done < <(vmt_list "$(pn "$c" routes)")
        x=$(pn "$c" mtu)
        [[ -z $x ]] || printf '  %-10s MTU %s\n' "" "$x"
    done
    x=$(cfg_node "$P_NODE" dns)
    a=$(cfg_node "$P_NODE" search)
    if [[ -n $x$a ]]; then
        if [[ -n $P_DNS_NIC ]]; then
            vmt_say "DNS          ${x:-없음}${a:+, 검색 도메인 $a} ([nic $P_DNS_NIC]에 붙인다)"
        else
            vmt_say "DNS          적용하지 않는다(붙일 NIC가 없다)"
        fi
    fi
    if (( ${#P_DEVS[@]} == 0 )); then
        vmt_say "추가 디스크  없음"
    else
        vmt_say "추가 디스크"
    fi
    for dev in "${P_DEVS[@]}"; do
        v=${P_DEV_VOLS[$dev]%% *}
        if [[ $(pd "$v" lvm) == yes ]]; then x="GPT 파티션 1개, LVM VG $(pd "$v" vg)"; else x="GPT"; fi
        [[ ${P_DEV_DONE[$dev]-} != 1 ]] || x="이미 만들었다. 다시 만들지 않는다"
        printf '  %-10s %s, %s\n' "$dev" "$(vmt_human_mib "${P_DEV_MIB[$dev]}")" "$x"
        # 한글은 printf 폭 계산(바이트)과 화면 폭이 달라 줄 끝에 둔다
        for v in ${P_DEV_VOLS[$dev]}; do
            sz=$(pd "$v" size)
            fs=$(pd "$v" fs)
            mnt=$(pd "$v" mount)
            x=$(pd "$v" options)
            [[ $x != defaults,nofail ]] || x=""
            printf '    %-12s %-5s %-6s %s%s\n' "$v" "$fs" "${sz:-나머지}" "${mnt:-마운트 안 함}" "${x:+ ($x)}"
        done
    done
    vmt_say "루트 확장    $R_DESC"
    vmt_say "설정 파일    $(os_net_desc)"
}
