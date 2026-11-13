# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# 노드 구성 파일(INI): 읽기, 검사, 쓰기
#
# 노드 목록(/etc/vmt/nodes.conf)은 템플릿에 둔다. 복제본의 vmt-reid가 그 가운데 하나를 골라 적용한다.
# 형식 설명은 src/nodes.conf.example(설치 위치 /etc/vmt/nodes.conf.example)에 있다.
#
#   [defaults]      모든 노드의 기본값
#   [node <이름>]   노드 하나
#   [nic <이름>]    바로 앞 [node]에 속한 NIC 하나
#   [disk <이름>]   바로 앞 [node]에 속한 볼륨 하나(파티션 또는 LVM 논리 볼륨)
#
# 읽은 값은 연관 배열 CFG에 둔다. 키 형식은 다음과 같다.
#   defaults.<키>   node.<노드>.<키>   nic.<노드>.<NIC>.<키>   disk.<노드>.<디스크>.<키>
# 순서는 CFG_NODES(노드 이름 목록), CFG_NICS[노드], CFG_DISKS[노드]에 공백으로 이어 둔다.
# CFG_LINE은 키와 구역 머리의 줄 번호를 기억한다. 오류 메시지에 쓴다.
# ─────────────────────────────────────────────────────────────────────────────

VMT_NODES_CONF=$VMT_ETC/nodes.conf   # 템플릿에 두는 노드 목록
VMT_NODE_CONF=$VMT_ETC/node.conf     # vmt-reid가 적용한 노드 구성 기록

# 구역 종류별로 쓸 수 있는 키. 파일에 쓸 때도 이 순서를 따른다
VMT_KEYS_defaults="domain dns search root_grow"
VMT_KEYS_node="hostname domain dns search root_grow"
VMT_KEYS_nic="interface method address gateway mtu routes"
VMT_KEYS_disk="device size fs mount options label lvm vg disk_size"

# 추가 디스크를 마운트하면 안 되는 경로
VMT_MOUNT_DENY="/boot /boot/efi /etc /usr /proc /sys /dev /run /bin /sbin /lib /lib64"

declare -A CFG=() CFG_LINE=() CFG_NICS=() CFG_DISKS=()
CFG_NODES=""
CFG_FILE=""
CFG_ERRS=()

# ── 값 형식 ─────────────────────────────────────────────────────────────────
vmt_valid_ip() {
    vmt_valid_cidr "$1/32"
}

# NIC, 디스크 구역 이름: 소문자로 시작하고 소문자, 숫자, 하이픈만 쓰며 15자 이하다
vmt_valid_item_name() {
    [[ $1 =~ ^[a-z][a-z0-9-]{0,14}$ ]]
}

# 쉼표로 이은 목록을 한 줄에 하나씩 출력한다. 앞뒤 공백과 빈 항목은 뺀다
vmt_list() {
    local x
    local -a parts
    IFS=, read -r -a parts <<<"$1"
    for x in "${parts[@]}"; do
        x=${x#"${x%%[![:space:]]*}"}
        x=${x%"${x##*[![:space:]]}"}
        [[ -n $x ]] && printf '%s\n' "$x"
    done
    return 0
}

# 크기 값(512M, 10G, 1T, 10GiB)을 MiB 수로 출력한다. 단위는 모두 1024 배수다. 형식이 틀리면 1을 돌려준다
vmt_size_mib() {
    local s=${1^^}
    s=${s%IB}
    [[ $s =~ ^([1-9][0-9]{0,6})([MGT])$ ]] || return 1
    case ${BASH_REMATCH[2]} in
        M) printf '%d' "${BASH_REMATCH[1]}" ;;
        G) printf '%d' $(( BASH_REMATCH[1] * 1024 )) ;;
        T) printf '%d' $(( BASH_REMATCH[1] * 1024 * 1024 )) ;;
    esac
}

# MiB 수를 읽기 쉬운 크기로 출력한다
vmt_human_mib() {
    local m=$1
    if (( m >= 1024 * 1024 && m % (1024 * 1024) == 0 )); then printf '%dT' $(( m / 1024 / 1024 ))
    elif (( m >= 1024 && m % 1024 == 0 )); then printf '%dG' $(( m / 1024 ))
    elif (( m >= 1024 )); then printf '%d.%dG' $(( m / 1024 )) $(( m % 1024 * 10 / 1024 ))
    else printf '%dM' "$m"
    fi
}

# 경로 "대상 via 게이트웨이"를 "대상 게이트웨이"로 출력한다. 형식이 틀리면 1을 돌려준다
vmt_route_parse() {
    local dst gw
    [[ $1 =~ ^([0-9./]+)[[:space:]]+via[[:space:]]+([0-9.]+)$ ]] || return 1
    # 검사 함수도 =~를 써서 BASH_REMATCH를 바꾸므로 먼저 옮겨 둔다
    dst=${BASH_REMATCH[1]}
    gw=${BASH_REMATCH[2]}
    vmt_valid_cidr "$dst" && vmt_valid_ip "$gw" || return 1
    printf '%s %s\n' "$dst" "$gw"
}

# IP/접두가 네트워크 주소(호스트 부분이 모두 0)인지 본다. ip route add가 이 형식만 받는다
vmt_is_network_cidr() {
    local p=$((10#${1#*/})) n
    n=$(vmt_ip2int "${1%/*}")
    (( p == 32 || (n & ((1 << (32 - p)) - 1)) == 0 ))
}

vmt_valid_mount() {
    local m=$1 d
    [[ $m =~ ^(/[A-Za-z0-9._-]+)+$ ]] || return 1
    [[ $m != */. && $m != */.. && $m != */./* && $m != */../* ]] || return 1
    for d in $VMT_MOUNT_DENY; do
        [[ $m == "$d" ]] && return 1
    done
    return 0
}

# 값 하나를 검사한다. 틀리면 설명을 출력한다. 빈 값은 "적지 않음"이므로 통과한다.
# 메뉴에서 입력을 받을 때도 같은 함수로 검사한다
vmt_value_error() {  # 구역 종류, 키, 값
    local t=$1 k=$2 v=$3 x
    [[ -n $v ]] || return 0
    case $t.$k in
        defaults.domain|node.domain)
            vmt_valid_fqdn "x.$v" || echo "도메인 형식이 맞지 않다: $v (예: lab.internal)" ;;
        node.hostname)
            vmt_valid_hostname "$v" || vmt_valid_fqdn "$v" \
                || echo "호스트명 형식이 맞지 않다: $v (예: web-01, web-01.lab.internal. 소문자로 시작하고 소문자·숫자·하이픈만 쓴다)" ;;
        defaults.dns|node.dns)
            while read -r x; do
                vmt_valid_ip "$x" || { echo "DNS 서버 주소가 맞지 않다: $x"; break; }
            done < <(vmt_list "$v") ;;
        defaults.search|node.search)
            while read -r x; do
                vmt_valid_fqdn "x.$x" || { echo "검색 도메인 형식이 맞지 않다: $x"; break; }
            done < <(vmt_list "$v") ;;
        defaults.root_grow|node.root_grow|disk.lvm)
            [[ $v == yes || $v == no ]] || echo "$k 값은 yes 또는 no다: $v" ;;
        nic.interface)
            x=${v,,}
            if [[ $x =~ ^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$ ]]; then
                echo "MAC으로 찾으려면 앞에 mac:을 붙인다: mac:${x//-/:}"
            elif ! [[ $x == auto || $x =~ ^mac:([0-9a-f]{2}:){5}[0-9a-f]{2}$ || $v =~ ^[A-Za-z0-9._-]{1,15}$ ]]; then
                echo "interface 값은 auto, 인터페이스 이름(예: enp0s8), mac:<MAC> 가운데 하나다: $v"
            fi ;;
        nic.method)
            [[ $v == static || $v == dhcp || $v == off ]] || echo "method 값은 static, dhcp, off 가운데 하나다: $v" ;;
        nic.address)
            while read -r x; do
                if ! vmt_valid_cidr "$x"; then echo "주소는 IP/접두 형식으로 쓴다: $x (예: 192.168.56.11/24)"; break; fi
                if ! vmt_usable_host_cidr "$x"; then echo "호스트 주소로 쓸 수 없는 IP다: $x (네트워크 주소, 브로드캐스트 주소, 루프백, 멀티캐스트)"; break; fi
            done < <(vmt_list "$v") ;;
        nic.gateway)
            vmt_valid_ip "$v" || echo "게이트웨이 주소가 맞지 않다: $v" ;;
        nic.mtu)
            [[ $v =~ ^[0-9]{3,4}$ ]] && (( 10#$v >= 576 && 10#$v <= 9000 )) || echo "mtu 값은 576~9000 사이의 정수다: $v" ;;
        nic.routes)
            while read -r x; do
                if ! vmt_route_parse "$x" >/dev/null; then echo "경로는 '대상 via 게이트웨이' 형식으로 쓴다: $x (예: 10.10.0.0/16 via 192.168.56.1)"; break; fi
                if ! vmt_is_network_cidr "${x%%[[:space:]]*}"; then echo "경로의 대상은 네트워크 주소로 쓴다: ${x%%[[:space:]]*}"; break; fi
            done < <(vmt_list "$v") ;;
        disk.device)
            [[ ${v#/dev/} =~ ^[a-z][a-z0-9]*$ ]] || echo "device 값은 디스크 이름이다: $v (예: sdb, vdb, nvme1n1)" ;;
        disk.size|disk.disk_size)
            vmt_size_mib "$v" >/dev/null || echo "$k 값은 512M, 10G, 1T 형식으로 쓴다(1024 배수): $v" ;;
        disk.fs)
            [[ $v == ext4 || $v == xfs || $v == none ]] || echo "fs 값은 ext4, xfs, none 가운데 하나다: $v" ;;
        disk.mount)
            vmt_valid_mount "$v" || echo "마운트 경로가 맞지 않다: $v (/로 시작하는 절대 경로. 쓸 수 없는 경로: $VMT_MOUNT_DENY)" ;;
        disk.options)
            [[ $v =~ ^[A-Za-z0-9_.,=:/@+-]+$ ]] || echo "options 값에 쓸 수 없는 문자가 있다: $v (예: defaults,nofail)" ;;
        disk.label)
            [[ $v =~ ^[A-Za-z0-9._-]{1,16}$ ]] || echo "label 값은 영문, 숫자, . _ -로 16자 이하다(xfs는 12자 이하): $v" ;;
        disk.vg)
            [[ $v =~ ^[A-Za-z0-9_+][A-Za-z0-9_.+-]{0,63}$ ]] || echo "vg 이름이 맞지 않다: $v" ;;
    esac
    return 0
}

# ── 읽기 ────────────────────────────────────────────────────────────────────
# INI 파일을 탭으로 구분한 레코드로 바꾼다. 한 줄에 하나다.
#   S <줄> <종류> <이름>   구역 머리
#   K <줄> <키> <값>       키와 값(앞뒤 공백, 따옴표, 줄 끝 주석을 뺀 값)
#   E <줄> <설명>          형식 오류
vmt_ini_records() {  # 파일
    awk '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        {
            sub(/\r$/, "")
            if (NR == 1) sub(/^\357\273\277/, "")
            t = trim($0)
            if (t == "" || t ~ /^[#;]/) next
            if (substr(t, 1, 1) == "[") {
                e = index(t, "]")
                if (e == 0) { printf "E\t%d\t대괄호가 닫히지 않았다\n", NR; next }
                rest = trim(substr(t, e + 1))
                if (rest != "" && rest !~ /^[#;]/) { printf "E\t%d\t구역 머리 뒤에 다른 내용이 있다\n", NR; next }
                n = split(trim(substr(t, 2, e - 2)), w, /[ \t]+/)
                if (n == 1)      printf "S\t%d\t%s\t\n", NR, tolower(w[1])
                else if (n == 2) printf "S\t%d\t%s\t%s\n", NR, tolower(w[1]), w[2]
                else             printf "E\t%d\t구역 머리는 [종류] 또는 [종류 이름]으로 쓴다\n", NR
                next
            }
            eq = index(t, "=")
            if (eq == 0) { printf "E\t%d\t키 = 값 형식이 아니다: %s\n", NR, t; next }
            k = tolower(trim(substr(t, 1, eq - 1)))
            v = trim(substr(t, eq + 1))
            q = substr(v, 1, 1)
            if (q == "\"" || q == "\047") {
                v = substr(v, 2)
                e = index(v, q)
                if (e == 0) { printf "E\t%d\t따옴표가 닫히지 않았다\n", NR; next }
                rest = trim(substr(v, e + 1))
                v = substr(v, 1, e - 1)
                if (rest != "" && rest !~ /^[#;]/) { printf "E\t%d\t닫는 따옴표 뒤에 다른 내용이 있다\n", NR; next }
            } else if (v ~ /^[#;]/) {
                v = ""
            } else if (match(v, /[ \t][#;]/)) {
                v = trim(substr(v, 1, RSTART - 1))
            }
            if (k == "") { printf "E\t%d\t키 이름이 없다\n", NR; next }
            if (index(v, "\t")) { printf "E\t%d\t값에 탭 문자가 있다\n", NR; next }
            printf "K\t%d\t%s\t%s\n", NR, k, v
        }' "$1"
}

cfg_err() {  # 줄 번호(0이면 없음), 설명
    if [[ $1 != 0 && -n $CFG_FILE ]]; then
        CFG_ERRS+=("$CFG_FILE:$1: $2")
    else
        CFG_ERRS+=("$2")
    fi
}

# CFG 키에 해당하는 줄 번호로 오류를 남긴다. 메뉴에서 넣은 값은 줄 번호가 없다
cfg_err_at() {  # CFG 키, 설명
    cfg_err "${CFG_LINE[$1]-0}" "$2"
}

vmt_cfg_reset() {
    CFG=()
    CFG_LINE=()
    CFG_NICS=()
    CFG_DISKS=()
    CFG_NODES=""
    CFG_FILE=""
    CFG_ERRS=()
}

# 파일을 읽어 CFG에 둔다. 형식 오류는 CFG_ERRS에 모은다. 값 검사는 vmt_cfg_validate가 한다.
# 잘못된 구역 머리 뒤의 키와 하위 구역은 따로 오류를 내지 않고 건너뛴다(같은 원인의 오류가 쌓이지 않게)
vmt_cfg_load() {  # 파일
    local tag ln a b sect="" node="" kind keys
    vmt_cfg_reset
    CFG_FILE=$1
    [[ -r $1 ]] || vmt_die "노드 목록을 읽지 못했다: $1"
    while IFS=$'\t' read -r tag ln a b; do
        case $tag in
            E)
                cfg_err "$ln" "$a"
                ;;
            S)
                sect="!"
                case $a in
                    defaults)
                        if [[ -n $b ]]; then cfg_err "$ln" "[defaults]에는 이름을 붙이지 않는다"; continue; fi
                        if [[ -n ${CFG_LINE[defaults]-} ]]; then cfg_err "$ln" "[defaults]가 두 번 나온다(처음: ${CFG_LINE[defaults]}번 줄)"; continue; fi
                        sect=defaults
                        ;;
                    node)
                        node="!"
                        if ! vmt_valid_hostname "$b"; then
                            cfg_err "$ln" "노드 이름이 맞지 않다: [node $b] (소문자로 시작하고 소문자·숫자·하이픈만 쓴다. 63자 이하)"
                            continue
                        fi
                        if [[ -n ${CFG_LINE[node.$b]-} ]]; then cfg_err "$ln" "노드 이름이 겹친다: $b (처음: ${CFG_LINE[node.$b]}번 줄)"; continue; fi
                        node=$b
                        CFG_NODES+="${CFG_NODES:+ }$b"
                        CFG_NICS[$b]=""
                        CFG_DISKS[$b]=""
                        sect=node.$b
                        ;;
                    nic|disk)
                        [[ $node != "!" ]] || continue
                        if [[ -z $node ]]; then cfg_err "$ln" "[$a $b]가 속할 [node]가 앞에 없다"; continue; fi
                        if ! vmt_valid_item_name "$b"; then
                            cfg_err "$ln" "이름이 맞지 않다: [$a $b] (소문자로 시작하고 소문자·숫자·하이픈만 쓴다. 15자 이하)"
                            continue
                        fi
                        if [[ -n ${CFG_LINE[$a.$node.$b]-} ]]; then cfg_err "$ln" "[$a $b]가 노드 $node 안에서 겹친다"; continue; fi
                        if [[ $a == nic ]]; then
                            CFG_NICS[$node]+="${CFG_NICS[$node]:+ }$b"
                        else
                            CFG_DISKS[$node]+="${CFG_DISKS[$node]:+ }$b"
                        fi
                        sect=$a.$node.$b
                        ;;
                    *)
                        cfg_err "$ln" "알 수 없는 구역: [$a${b:+ $b}]. 쓸 수 있는 구역: defaults, node, nic, disk"
                        continue
                        ;;
                esac
                CFG_LINE[$sect]=$ln
                ;;
            K)
                [[ $sect != "!" ]] || continue
                if [[ -z $sect ]]; then cfg_err "$ln" "구역 머리보다 앞에 키가 있다: $a"; continue; fi
                kind=${sect%%.*}
                keys=VMT_KEYS_$kind
                if [[ " ${!keys} " != *" $a "* ]]; then
                    cfg_err "$ln" "[$kind]에 쓸 수 없는 키: $a (쓸 수 있는 키: ${!keys})"
                    continue
                fi
                if [[ -n ${CFG_LINE[$sect.$a]-} ]]; then cfg_err "$ln" "키가 겹친다: $a (처음: ${CFG_LINE[$sect.$a]}번 줄)"; continue; fi
                CFG_LINE[$sect.$a]=$ln
                if [[ -n $b ]]; then CFG[$sect.$a]=$b; fi
                ;;
        esac
    done < <(vmt_ini_records "$1")
    return 0
}

# ── 값 읽기 ─────────────────────────────────────────────────────────────────
# 노드 값. 노드에 없으면 [defaults] 값을 쓴다(domain, dns, search, root_grow)
cfg_node() {  # 노드, 키
    local v=${CFG[node.$1.$2]-}
    [[ -n $v ]] || v=${CFG[defaults.$2]-}
    if [[ -z $v && $2 == root_grow ]]; then v=no; fi
    printf '%s' "$v"
}

# 노드의 호스트명 값. 적지 않았으면 노드 이름이다
cfg_hostname() {  # 노드
    local v=${CFG[node.$1.hostname]-}
    printf '%s' "${v:-$1}"
}

# NIC 값. 적지 않은 키는 기본값을 쓴다(interface = auto, method = static)
cfg_nic() {  # 노드, NIC, 키
    local v=${CFG[nic.$1.$2.$3]-}
    if [[ -z $v ]]; then
        case $3 in
            interface) v=auto ;;
            method)    v=static ;;
        esac
    fi
    [[ $3 == interface && $v == mac:* ]] && v=${v,,}
    printf '%s' "$v"
}

# 디스크 값. 적지 않은 키는 기본값을 쓴다(fs = ext4, options = defaults,nofail, lvm = no, vg = vg_<디스크>)
cfg_disk() {  # 노드, 디스크, 키
    local v=${CFG[disk.$1.$2.$3]-}
    if [[ -z $v ]]; then
        case $3 in
            fs)      v=ext4 ;;
            options) v=defaults,nofail ;;
            lvm)     v=no ;;
            vg)      [[ $(cfg_disk "$1" "$2" lvm) == yes ]] && v=vg_$(cfg_disk "$1" "$2" device) ;;
        esac
    fi
    [[ $3 == device ]] && v=${v#/dev/}
    [[ $3 == size || $3 == disk_size ]] && v=${v^^} && v=${v%IB}
    printf '%s' "$v"
}

# ── 검사 ────────────────────────────────────────────────────────────────────
# 하드웨어와 무관한 검사만 한다. 오류는 CFG_ERRS에 모은다. 하드웨어 대조는 vmt_plan_build가 한다
vmt_cfg_validate() {
    local k n msg
    for k in $VMT_KEYS_defaults; do
        msg=$(vmt_value_error defaults "$k" "${CFG[defaults.$k]-}")
        [[ -z $msg ]] || cfg_err_at "defaults.$k" "[defaults] $msg"
    done
    for n in $CFG_NODES; do
        vmt_cfg_validate_node "$n"
    done
    return 0
}

vmt_cfg_validate_node() {  # 노드
    local n=$1 k c d v msg m addr gw x dev
    local -a nics disks addrs
    local -A seen_if=() seen_mount=() dev_lvm=() dev_vg=() dev_dsize=() dev_unsized=()
    local autos=0 gws=0 usable=0

    for k in $VMT_KEYS_node; do
        msg=$(vmt_value_error node "$k" "${CFG[node.$n.$k]-}")
        [[ -z $msg ]] || cfg_err_at "node.$n.$k" "[node $n] $msg"
    done

    read -r -a nics <<<"${CFG_NICS[$n]-}"
    for c in "${nics[@]}"; do
        for k in $VMT_KEYS_nic; do
            msg=$(vmt_value_error nic "$k" "${CFG[nic.$n.$c.$k]-}")
            [[ -z $msg ]] || cfg_err_at "nic.$n.$c.$k" "[node $n] [nic $c] $msg"
        done
        m=$(cfg_nic "$n" "$c" method)
        v=$(cfg_nic "$n" "$c" interface)
        if [[ $v == auto ]]; then
            autos=$((autos + 1))
            (( autos <= 1 )) || cfg_err_at "nic.$n.$c.interface" "[node $n] [nic $c] interface = auto는 노드마다 NIC 하나에만 쓴다. 나머지는 이름이나 mac:<MAC>으로 적는다"
        elif [[ -n ${seen_if[$v]-} ]]; then
            cfg_err_at "nic.$n.$c.interface" "[node $n] [nic $c] [nic ${seen_if[$v]}]와 같은 NIC를 가리킨다: $v"
        else
            seen_if[$v]=$c
        fi
        mapfile -t addrs < <(vmt_list "${CFG[nic.$n.$c.address]-}")
        case $m in
            static)
                usable=1
                (( ${#addrs[@]} )) || cfg_err_at "nic.$n.$c" "[node $n] [nic $c] method = static이면 address가 있어야 한다"
                ;;
            dhcp|off)
                [[ $m == dhcp ]] && usable=1
                (( ${#addrs[@]} == 0 )) || cfg_err_at "nic.$n.$c.address" "[node $n] [nic $c] method = $m에는 address를 쓰지 않는다"
                [[ -z ${CFG[nic.$n.$c.gateway]-} ]] || cfg_err_at "nic.$n.$c.gateway" "[node $n] [nic $c] gateway는 method = static에만 쓴다"
                [[ $m == dhcp || -z ${CFG[nic.$n.$c.routes]-} ]] || cfg_err_at "nic.$n.$c.routes" "[node $n] [nic $c] method = off에는 routes를 쓰지 않는다"
                ;;
        esac
        gw=${CFG[nic.$n.$c.gateway]-}
        if [[ -n $gw && $m == static ]]; then
            gws=$((gws + 1))
            (( gws <= 1 )) || cfg_err_at "nic.$n.$c.gateway" "[node $n] [nic $c] gateway는 노드마다 NIC 하나에만 쓴다"
            vmt_ip_in_any "$gw" "${addrs[@]}" || cfg_err_at "nic.$n.$c.gateway" "[node $n] [nic $c] gateway $gw가 이 NIC의 대역(${addrs[*]}) 밖에 있다"
        fi
        if [[ $m == static ]]; then
            while read -r x; do
                x=$(vmt_route_parse "$x") || continue
                vmt_ip_in_any "${x#* }" "${addrs[@]}" \
                    || cfg_err_at "nic.$n.$c.routes" "[node $n] [nic $c] 경로의 게이트웨이 ${x#* }가 이 NIC의 대역(${addrs[*]}) 밖에 있다"
            done < <(vmt_list "${CFG[nic.$n.$c.routes]-}")
        fi
        # 다른 NIC와 대역이 겹치면 같은 대역에 NIC가 둘이 되어 응답 경로가 꼬인다
        for addr in "${addrs[@]}"; do
            vmt_valid_cidr "$addr" || continue
            for d in "${nics[@]}"; do
                [[ $d != "$c" ]] || break
                while read -r x; do
                    vmt_valid_cidr "$x" && vmt_cidr_overlap "$addr" "$x" \
                        && cfg_err_at "nic.$n.$c.address" "[node $n] [nic $c] $addr가 [nic $d]의 $x와 대역이 겹친다"
                done < <(vmt_list "${CFG[nic.$n.$d.address]-}")
            done
        done
    done
    if [[ -n ${CFG[node.$n.dns]-}${CFG[node.$n.search]-} ]] && (( ! usable )); then
        cfg_err_at "node.$n" "[node $n] dns나 search를 붙일 NIC가 없다. method = static 또는 dhcp인 NIC가 있어야 한다"
    fi

    read -r -a disks <<<"${CFG_DISKS[$n]-}"
    for d in "${disks[@]}"; do
        for k in $VMT_KEYS_disk; do
            msg=$(vmt_value_error disk "$k" "${CFG[disk.$n.$d.$k]-}")
            [[ -z $msg ]] || cfg_err_at "disk.$n.$d.$k" "[node $n] [disk $d] $msg"
        done
        dev=$(cfg_disk "$n" "$d" device)
        if [[ -z $dev ]]; then
            cfg_err_at "disk.$n.$d" "[node $n] [disk $d] device가 없다(예: device = sdb)"
            continue
        fi
        v=$(cfg_disk "$n" "$d" fs)
        m=${CFG[disk.$n.$d.mount]-}
        if [[ $v == none ]]; then
            [[ -z $m ]] || cfg_err_at "disk.$n.$d.mount" "[node $n] [disk $d] fs = none에는 mount를 쓰지 않는다"
            [[ -z ${CFG[disk.$n.$d.label]-} ]] || cfg_err_at "disk.$n.$d.label" "[node $n] [disk $d] fs = none에는 label을 쓰지 않는다"
        else
            [[ -n $m ]] || cfg_err_at "disk.$n.$d" "[node $n] [disk $d] mount가 없다. 마운트하지 않으려면 fs = none으로 둔다"
        fi
        if [[ -n $m ]]; then
            if [[ -n ${seen_mount[$m]-} ]]; then
                cfg_err_at "disk.$n.$d.mount" "[node $n] [disk $d] [disk ${seen_mount[$m]}]와 마운트 경로가 같다: $m"
            else
                seen_mount[$m]=$d
            fi
        fi
        x=${CFG[disk.$n.$d.label]-}
        if [[ $v == xfs && ${#x} -gt 12 ]]; then
            cfg_err_at "disk.$n.$d.label" "[node $n] [disk $d] xfs의 label은 12자 이하다: $x"
        fi
        # 같은 디스크의 볼륨끼리 맞아야 하는 값
        k=$(cfg_disk "$n" "$d" lvm)
        if [[ -z ${dev_lvm[$dev]-} ]]; then
            dev_lvm[$dev]=$k
            dev_vg[$dev]=$(cfg_disk "$n" "$d" vg)
        else
            [[ ${dev_lvm[$dev]} == "$k" ]] || cfg_err_at "disk.$n.$d.lvm" "[node $n] [disk $d] 같은 디스크($dev)의 볼륨은 lvm 값이 같아야 한다"
            [[ ${dev_vg[$dev]} == "$(cfg_disk "$n" "$d" vg)" ]] || cfg_err_at "disk.$n.$d.vg" "[node $n] [disk $d] 같은 디스크($dev)의 볼륨은 vg 값이 같아야 한다"
        fi
        [[ $k == yes || -z ${CFG[disk.$n.$d.vg]-} ]] || cfg_err_at "disk.$n.$d.vg" "[node $n] [disk $d] vg는 lvm = yes일 때만 쓴다"
        x=$(cfg_disk "$n" "$d" disk_size)
        if [[ -n $x ]]; then
            if [[ -n ${dev_dsize[$dev]-} && ${dev_dsize[$dev]} != "$x" ]]; then
                cfg_err_at "disk.$n.$d.disk_size" "[node $n] [disk $d] 같은 디스크($dev)의 disk_size가 서로 다르다"
            fi
            dev_dsize[$dev]=$x
        fi
        # 크기를 적지 않은 볼륨(남은 공간 전체)은 그 디스크의 마지막 볼륨이어야 한다
        if [[ -n ${dev_unsized[$dev]-} ]]; then
            cfg_err_at "disk.$n.${dev_unsized[$dev]}" "[node $n] [disk ${dev_unsized[$dev]}] size가 없다. 남은 공간을 모두 쓰는 볼륨은 디스크($dev)의 마지막 볼륨이어야 한다"
            dev_unsized[$dev]=""
        fi
        [[ -n $(cfg_disk "$n" "$d" size) ]] || dev_unsized[$dev]=$d
    done

    os_cfg_validate_node "$n"
    return 0
}

# IP가 주어진 IP/접두 가운데 하나의 대역 안에 있는지 본다
vmt_ip_in_any() {  # IP, IP/접두...
    local ip=$1 c
    shift
    for c in "$@"; do
        vmt_valid_cidr "$c" || continue
        vmt_cidr_overlap "$ip/32" "$c" && return 0
    done
    return 1
}

# 오류가 있으면 모두 출력하고 끝낸다
vmt_cfg_die_on_errors() {
    (( ${#CFG_ERRS[@]} )) || return 0
    local e
    printf '%s: 노드 구성에 오류가 %d개 있다\n' "$PROG" "${#CFG_ERRS[@]}" >&2
    for e in "${CFG_ERRS[@]}"; do
        printf '  %s\n' "$e" >&2
    done
    exit 1
}

# 노드 목록 파일을 읽고 검사한다. 오류가 있으면 끝낸다
vmt_cfg_load_checked() {  # 파일
    vmt_cfg_load "$1"
    vmt_cfg_validate
    vmt_cfg_die_on_errors
}

# ── 쓰기 ────────────────────────────────────────────────────────────────────
cfg_emit_kv() {  # 키, 값
    local v=$2
    [[ -n $v ]] || return 0
    # 주석으로 읽힐 수 있는 값은 따옴표로 감싼다
    if [[ $v =~ [[:space:]][#\;] || $v == [\#\;\"\']* ]]; then
        v="\"$v\""
    fi
    printf '%s = %s\n' "$1" "$v"
}

# CFG를 INI로 출력한다. 노드를 주면 그 노드만 출력하고, [defaults] 값을 노드에 합친다
vmt_cfg_render() {  # [노드]
    local only=${1:-} n c d k v
    if [[ -z $only ]]; then
        v=""
        for k in $VMT_KEYS_defaults; do v+=${CFG[defaults.$k]-}; done
        if [[ -n $v ]]; then
            printf '[defaults]\n'
            for k in $VMT_KEYS_defaults; do cfg_emit_kv "$k" "${CFG[defaults.$k]-}"; done
        fi
    fi
    for n in $CFG_NODES; do
        [[ -z $only || $n == "$only" ]] || continue
        printf '\n[node %s]\n' "$n"
        for k in $VMT_KEYS_node; do
            v=${CFG[node.$n.$k]-}
            if [[ -n $only && -z $v && $k != hostname ]]; then v=${CFG[defaults.$k]-}; fi
            cfg_emit_kv "$k" "$v"
        done
        for c in ${CFG_NICS[$n]-}; do
            printf '\n[nic %s]\n' "$c"
            for k in $VMT_KEYS_nic; do cfg_emit_kv "$k" "${CFG[nic.$n.$c.$k]-}"; done
        done
        for d in ${CFG_DISKS[$n]-}; do
            printf '\n[disk %s]\n' "$d"
            for k in $VMT_KEYS_disk; do cfg_emit_kv "$k" "${CFG[disk.$n.$d.$k]-}"; done
        done
    done
    return 0
}

# 노드 목록 파일을 다시 쓴다. 바로 전 파일은 .bak으로 하나 남긴다
vmt_cfg_save() {  # 파일
    local f=$1 tmp
    tmp=$(mktemp)
    {
        printf '# vmt 노드 목록. vmt-nodes %s가 %s에 다시 썼다\n' "$VMT_VERSION" "$(date -Is)"
        printf '# 형식 설명: %s.example\n\n' "$VMT_NODES_CONF"
        vmt_cfg_render
    } > "$tmp"
    mkdir -p "${f%/*}"
    [[ -f $f ]] && cp -p "$f" "$f.bak"
    vmt_install_file "$tmp" "$f" 644
}

# ── 목록 다루기 ─────────────────────────────────────────────────────────────
# 공백으로 이은 목록에서 항목 하나를 뺀 결과를 출력한다
vmt_words_without() {  # 목록, 항목
    local w out=""
    for w in $1; do
        [[ $w == "$2" ]] || out+="${out:+ }$w"
    done
    printf '%s' "$out"
}

# 노드, NIC, 디스크와 그 값을 모두 지운다
vmt_cfg_drop() {  # 접두(node.<노드> | nic.<노드>.<NIC> | disk.<노드>.<디스크>)
    local k
    for k in "${!CFG[@]}"; do
        [[ $k == "$1" || $k == "$1".* ]] && unset "CFG[$k]"
    done
    for k in "${!CFG_LINE[@]}"; do
        [[ $k == "$1" || $k == "$1".* ]] && unset "CFG_LINE[$k]"
    done
    return 0
}

vmt_cfg_remove_node() {  # 노드
    local c d
    for c in ${CFG_NICS[$1]-}; do vmt_cfg_drop "nic.$1.$c"; done
    for d in ${CFG_DISKS[$1]-}; do vmt_cfg_drop "disk.$1.$d"; done
    vmt_cfg_drop "node.$1"
    unset "CFG_NICS[$1]" "CFG_DISKS[$1]"
    CFG_NODES=$(vmt_words_without "$CFG_NODES" "$1")
}

# 노드 요약 한 줄: 호스트명, NIC 수와 첫 주소, 디스크 수
vmt_cfg_node_brief() {  # 노드
    local n=$1 nics=0 disks=0 c first=""
    for c in ${CFG_NICS[$n]-}; do
        nics=$((nics + 1))
        if [[ -z $first ]]; then
            case $(cfg_nic "$n" "$c" method) in
                static) first=$(vmt_list_first "${CFG[nic.$n.$c.address]-}") ;;
                dhcp)   first=DHCP ;;
            esac
        fi
    done
    for c in ${CFG_DISKS[$n]-}; do disks=$((disks + 1)); done
    printf '%s  NIC %d%s, 디스크 %d' "$(cfg_hostname "$n")" "$nics" "${first:+ ($first)}" "$disks"
}
