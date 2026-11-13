# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# 대화형 메뉴: vmt-reid(복제본)와 vmt-nodes(템플릿)가 함께 쓴다
#
# 번호나 글자를 입력해 고른다. 값을 물을 때는 [ ] 안에 지금 값을 보여 준다.
#   엔터     지금 값을 그대로 둔다
#   -        값을 지운다(기본값으로 돌아간다)
# 표준 입력이 끝나면(Ctrl+D, 파이프 입력의 끝) 저장하지 않고 끝낸다.
# 입력을 파이프로 넘길 수 있으므로 안내는 표준 출력에, 입력은 표준 입력에서 받는다.
# ─────────────────────────────────────────────────────────────────────────────

MENU_CONTEXT=""    # reid(복제본) 또는 nodes(템플릿)
MENU_DIRTY=0       # 저장하지 않은 변경이 있으면 1
MENU_ITEMS=()      # 노드 메뉴의 번호별 항목(nic:<이름>, disk:<이름>)

menu_read() {  # 변수 이름, 안내
    local menu_in
    printf '%s' "$2"
    if ! IFS= read -r menu_in; then
        printf '\n'
        vmt_die "입력이 끝났다. 저장하지 않은 변경은 버린다"
    fi
    menu_in=${menu_in%$'\r'}
    menu_in=${menu_in#"${menu_in%%[![:space:]]*}"}
    menu_in=${menu_in%"${menu_in##*[![:space:]]}"}
    printf -v "$1" '%s' "$menu_in"
}

menu_yes() {  # 안내
    local a
    menu_read a "$1 [y/N]: "
    [[ $a == [yY] || $a == [yY][eE][sS] ]]
}

# 값이 비었을 때 보여 줄 설명
menu_show() {  # 값, 기본값 설명
    if [[ -n $1 ]]; then printf '%s' "$1"
    elif [[ -n $2 ]]; then printf '(%s)' "$2"
    else printf '(없음)'
    fi
}

# 노드 값이 비었을 때 쓰일 값의 설명
menu_node_default() {  # 키
    local v=${CFG[defaults.$1]-}
    if [[ -n $v ]]; then
        printf '공통값 %s' "$v"
    elif [[ $1 == root_grow ]]; then
        printf 'no'
    elif [[ $1 == domain && ${VMT_TPL_FQDN:-} == *.* ]]; then
        printf '템플릿 도메인 %s' "${VMT_TPL_FQDN#*.}"
    fi
}

# CFG 값 하나를 묻는다. 틀린 값은 이유를 보여 주고 다시 묻는다.
# 필수 값이면(required = 1) 빈 값으로 넘어가지 못한다
menu_field() {  # 구역 종류, 키, CFG 키, 안내, 기본값 설명, [required]
    local t=$1 k=$2 ck=$3 label=$4 dflt=${5:-} req=${6:-0} in msg
    while :; do
        menu_read in "  $label [$(menu_show "${CFG[$ck]-}" "$dflt")]: "
        case $in in
            "")
                if (( req )) && [[ -z ${CFG[$ck]-} ]]; then
                    printf '  ! 값이 있어야 한다\n'
                    continue
                fi
                return 0
                ;;
            -)
                if (( req )); then
                    printf '  ! 지울 수 없는 값이다\n'
                    continue
                fi
                unset "CFG[$ck]"
                MENU_DIRTY=1
                return 0
                ;;
        esac
        msg=$(vmt_value_error "$t" "$k" "$in")
        if [[ -z $msg ]]; then
            CFG[$ck]=$in
            MENU_DIRTY=1
            return 0
        fi
        printf '  ! %s\n' "$msg"
    done
}

# 새 NIC·디스크·노드 이름을 묻는다
menu_new_name() {  # 변수 이름, 안내, 기본값, 이미 있는 이름 목록, 종류(item|node)
    local menu_nm
    while :; do
        menu_read menu_nm "  $2 [$3]: "
        menu_nm=${menu_nm:-$3}
        if [[ $5 == node ]]; then
            vmt_valid_hostname "$menu_nm" || { printf '  ! 소문자로 시작하고 소문자·숫자·하이픈만 쓴다(63자 이하)\n'; continue; }
        else
            vmt_valid_item_name "$menu_nm" || { printf '  ! 소문자로 시작하고 소문자·숫자·하이픈만 쓴다(15자 이하)\n'; continue; }
        fi
        if [[ " $4 " == *" $menu_nm "* ]]; then
            printf '  ! 이미 있는 이름이다: %s\n' "$menu_nm"
            continue
        fi
        printf -v "$1" '%s' "$menu_nm"
        return 0
    done
}

# 목록에 없는 첫 이름. 시작 번호를 주면 기본 이름 뒤에 번호를 붙여 시작한다(nic2, nic3 ...)
menu_free_name() {  # 기본 이름, 목록, [시작 번호]
    local i=${3:-} nm
    nm=$1$i
    while [[ " $2 " == *" $nm "* ]]; do
        i=$(( ${i:-1} + 1 ))
        nm=$1$i
    done
    printf '%s' "$nm"
}

menu_nic_brief() {  # 노드, NIC
    local n=$1 c=$2 m a
    m=$(cfg_nic "$n" "$c" method)
    a=${CFG[nic.$n.$c.address]-}
    printf '%s, %s%s' "$(cfg_nic "$n" "$c" interface)" "$m" "${a:+ $a}"
}

menu_disk_brief() {  # 노드, 디스크
    local n=$1 d=$2 sz m
    sz=$(cfg_disk "$n" "$d" size)
    m=${CFG[disk.$n.$d.mount]-}
    printf '%s, %s, %s%s' "$(cfg_disk "$n" "$d" device)" "${sz:-나머지}" "$(cfg_disk "$n" "$d" fs)" "${m:+, $m}"
}

# 이 VM에서 고를 수 있는 NIC와 디스크를 안내한다
menu_nic_hint() {
    if [[ $MENU_CONTEXT == reid ]]; then
        printf '  이 VM의 NIC: %s\n' "$(vmt_nic_inventory)"
    else
        printf '  템플릿에는 NAT NIC만 있다. 복제본에 붙일 NIC는 auto(후보가 하나일 때), 이름, mac:<MAC>으로 적는다\n'
    fi
}

menu_disk_hint() {
    printf '  이 VM의 디스크: %s\n' "$(vmt_disk_inventory)"
    [[ $MENU_CONTEXT == reid ]] || printf '  복제본에 붙일 디스크 이름은 보통 sdb, sdc 순서다(VirtualBox SATA, Hyper-V SCSI)\n'
}

menu_nic_edit() {  # 노드, NIC
    local n=$1 c=$2 p=nic.$1.$2 m
    printf '\n-- NIC %s --\n' "$c"
    menu_nic_hint
    menu_field nic interface "$p.interface" "interface (auto, 인터페이스 이름, mac:<MAC>)" "auto"
    menu_field nic method "$p.method" "method (static, dhcp, off)" "static"
    m=$(cfg_nic "$n" "$c" method)
    if [[ $m == static ]]; then
        menu_field nic address "$p.address" "address (IP/접두, 여러 개면 쉼표로 구분)" "" 1
        menu_field nic gateway "$p.gateway" "gateway (기본 경로를 이 NIC로 옮길 때만)"
    else
        if [[ -n ${CFG[$p.address]-}${CFG[$p.gateway]-} ]]; then
            unset "CFG[$p.address]" "CFG[$p.gateway]"
            printf '  method = %s라 address와 gateway를 지웠다\n' "$m"
        fi
        if [[ $m == off && -n ${CFG[$p.routes]-} ]]; then
            unset "CFG[$p.routes]"
            printf '  method = off라 routes를 지웠다\n'
        fi
    fi
    if menu_yes "  mtu, routes도 고칠까?"; then
        menu_field nic mtu "$p.mtu" "mtu (576~9000)"
        [[ $m == off ]] || menu_field nic routes "$p.routes" "routes (대상 via 게이트웨이, 여러 개면 쉼표로 구분)"
    fi
}

menu_disk_edit() {  # 노드, 디스크
    local n=$1 d=$2 p=disk.$1.$2 fs
    printf '\n-- 디스크 %s --\n' "$d"
    menu_disk_hint
    menu_field disk device "$p.device" "device (예: sdb)" "" 1
    menu_field disk size "$p.size" "size (예: 10G. 비우면 남은 공간 전체)" "나머지"
    menu_field disk fs "$p.fs" "fs (ext4, xfs, none)" "ext4"
    fs=$(cfg_disk "$n" "$d" fs)
    if [[ $fs == none ]]; then
        if [[ -n ${CFG[$p.mount]-}${CFG[$p.label]-} ]]; then
            unset "CFG[$p.mount]" "CFG[$p.label]"
            printf '  fs = none이라 mount와 label을 지웠다\n'
        fi
    else
        menu_field disk mount "$p.mount" "mount (예: /data)" "" 1
    fi
    if menu_yes "  options, label, lvm, vg, disk_size도 고칠까?"; then
        [[ $fs == none ]] || menu_field disk options "$p.options" "options" "defaults,nofail"
        [[ $fs == none ]] || menu_field disk label "$p.label" "label (ext4 16자, xfs 12자 이하)"
        menu_field disk lvm "$p.lvm" "lvm (yes면 디스크 전체를 PV로 만들고 볼륨마다 LV를 만든다)" "no"
        if [[ $(cfg_disk "$n" "$d" lvm) == yes ]]; then
            menu_field disk vg "$p.vg" "vg" "vg_$(cfg_disk "$n" "$d" device)"
        elif [[ -n ${CFG[$p.vg]-} ]]; then
            unset "CFG[$p.vg]"
        fi
        menu_field disk disk_size "$p.disk_size" "disk_size (디스크 크기 확인용, 예: 20G)"
    fi
}

menu_nic_add() {  # 노드
    local n=$1 c dflt
    local -a cur
    read -r -a cur <<<"${CFG_NICS[$n]-}"
    if (( ${#cur[@]} == 0 )); then dflt=mgmt; else dflt=$(menu_free_name nic "${CFG_NICS[$n]}" $(( ${#cur[@]} + 1 ))); fi
    menu_new_name c "새 NIC 이름" "$dflt" "${CFG_NICS[$n]-}" item
    CFG_NICS[$n]+="${CFG_NICS[$n]:+ }$c"
    MENU_DIRTY=1
    menu_nic_edit "$n" "$c"
}

menu_disk_add() {  # 노드
    local n=$1 d
    menu_new_name d "새 디스크(볼륨) 이름" "$(menu_free_name data "${CFG_DISKS[$n]-}")" "${CFG_DISKS[$n]-}" item
    CFG_DISKS[$n]+="${CFG_DISKS[$n]:+ }$d"
    MENU_DIRTY=1
    menu_disk_edit "$n" "$d"
}

menu_item_delete() {  # 노드
    local n=$1 ch it
    menu_read ch "  지울 NIC·디스크 번호: "
    if [[ ! $ch =~ ^[0-9]+$ || -z ${MENU_ITEMS[ch]-} ]]; then
        printf '  ! 목록에 없는 번호다: %s\n' "$ch"
        return 0
    fi
    it=${MENU_ITEMS[ch]}
    case $it in
        nic:*)
            vmt_cfg_drop "nic.$n.${it#nic:}"
            CFG_NICS[$n]=$(vmt_words_without "${CFG_NICS[$n]-}" "${it#nic:}")
            ;;
        disk:*)
            vmt_cfg_drop "disk.$n.${it#disk:}"
            CFG_DISKS[$n]=$(vmt_words_without "${CFG_DISKS[$n]-}" "${it#disk:}")
            ;;
    esac
    MENU_DIRTY=1
    printf '  지웠다: %s\n' "${it/:/ }"
}

menu_node_edit() {  # 노드
    local n=$1 ch i c d
    while :; do
        printf '\n== 노드 %s ==\n' "$n"
        printf '  1) 호스트명            %s\n' "$(menu_show "${CFG[node.$n.hostname]-}" "노드 이름 $n")"
        printf '  2) 도메인              %s\n' "$(menu_show "${CFG[node.$n.domain]-}" "$(menu_node_default domain)")"
        printf '  3) DNS 서버            %s\n' "$(menu_show "${CFG[node.$n.dns]-}" "$(menu_node_default dns)")"
        printf '  4) DNS 검색 도메인     %s\n' "$(menu_show "${CFG[node.$n.search]-}" "$(menu_node_default search)")"
        printf '  5) 루트 디스크 확장    %s\n' "$(menu_show "${CFG[node.$n.root_grow]-}" "$(menu_node_default root_grow)")"
        MENU_ITEMS=()
        i=5
        # 이름 칸은 영문만 들어가므로 폭을 맞출 수 있다. 한글은 바이트 수와 화면 폭이 달라 칸 끝에 둔다
        printf '  NIC\n'
        [[ -n ${CFG_NICS[$n]-} ]] || printf '     (없음)\n'
        for c in ${CFG_NICS[$n]-}; do
            i=$((i + 1))
            MENU_ITEMS[i]=nic:$c
            printf '  %d) %-16s %s\n' "$i" "$c" "$(menu_nic_brief "$n" "$c")"
        done
        printf '  디스크\n'
        [[ -n ${CFG_DISKS[$n]-} ]] || printf '     (없음)\n'
        for d in ${CFG_DISKS[$n]-}; do
            i=$((i + 1))
            MENU_ITEMS[i]=disk:$d
            printf '  %d) %-16s %s\n' "$i" "$d" "$(menu_disk_brief "$n" "$d")"
        done
        printf '  n) NIC 추가   d) 디스크 추가   x) NIC·디스크 지우기   b) 끝\n'
        menu_read ch "선택: "
        case $ch in
            1) menu_field node hostname "node.$n.hostname" "호스트명 (짧은 이름 또는 FQDN)" "노드 이름 $n" ;;
            2) menu_field node domain "node.$n.domain" "도메인" "$(menu_node_default domain)" ;;
            3) menu_field node dns "node.$n.dns" "DNS 서버 (여러 개면 쉼표로 구분)" "$(menu_node_default dns)" ;;
            4) menu_field node search "node.$n.search" "DNS 검색 도메인 (여러 개면 쉼표로 구분)" "$(menu_node_default search)" ;;
            5) menu_field node root_grow "node.$n.root_grow" "루트 디스크 확장 (yes, no)" "$(menu_node_default root_grow)" ;;
            n) menu_nic_add "$n" ;;
            d) menu_disk_add "$n" ;;
            x) menu_item_delete "$n" ;;
            b) return 0 ;;
            "") ;;
            *)
                if [[ $ch =~ ^[0-9]+$ && -n ${MENU_ITEMS[ch]-} ]]; then
                    case ${MENU_ITEMS[ch]} in
                        nic:*)  menu_nic_edit "$n" "${MENU_ITEMS[ch]#nic:}" ;;
                        disk:*) menu_disk_edit "$n" "${MENU_ITEMS[ch]#disk:}" ;;
                    esac
                else
                    printf '  ! 목록에 없는 선택이다: %s\n' "$ch"
                fi
                ;;
        esac
    done
}

menu_defaults_edit() {
    printf '\n-- 공통값([defaults]) --\n'
    printf '  노드에 같은 키가 없을 때 쓰는 값이다\n'
    menu_field defaults domain defaults.domain "도메인"
    menu_field defaults dns defaults.dns "DNS 서버 (여러 개면 쉼표로 구분)"
    menu_field defaults search defaults.search "DNS 검색 도메인 (여러 개면 쉼표로 구분)"
    menu_field defaults root_grow defaults.root_grow "루트 디스크 확장 (yes, no)" "no"
}

menu_new_node() {  # 결과 노드 이름을 둘 변수 이름
    local menu_node
    menu_new_name menu_node "새 노드 이름(호스트명으로도 쓴다)" "$(menu_free_name node "$CFG_NODES" 1)" "$CFG_NODES" node
    CFG_NODES+="${CFG_NODES:+ }$menu_node"
    CFG_NICS[$menu_node]=""
    CFG_DISKS[$menu_node]=""
    MENU_DIRTY=1
    printf -v "$1" '%s' "$menu_node"
}

# 노드 목록을 번호와 함께 출력한다
menu_list_nodes() {
    local i=0 n
    if [[ -z $CFG_NODES ]]; then
        printf '  (노드 없음)\n'
        return 0
    fi
    for n in $CFG_NODES; do
        i=$((i + 1))
        printf '  %d) %-16s %s\n' "$i" "$n" "$(vmt_cfg_node_brief "$n")"
    done
}

# 번호를 노드 이름으로 바꾼다
menu_pick_node() {  # 변수 이름, 번호
    local -a list
    read -r -a list <<<"$CFG_NODES"
    [[ $2 =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= ${#list[@]} )) || return 1
    printf -v "$1" '%s' "${list[$2 - 1]}"
}

menu_show_errors() {
    local e
    printf '노드 구성에 오류가 %d개 있다\n' "${#CFG_ERRS[@]}"
    for e in "${CFG_ERRS[@]}"; do
        printf '  %s\n' "$e"
    done
}

# ── vmt-reid 메뉴 ───────────────────────────────────────────────────────────
# 고른 노드를 REID_NODE에 둔다. 적용(a)을 고를 때까지 아무것도 바꾸지 않는다
vmt_reid_menu() {
    local ch n
    MENU_CONTEXT=reid
    if [[ -f $VMT_NODES_CONF ]]; then
        vmt_cfg_load "$VMT_NODES_CONF"
        vmt_cfg_validate
        if (( ${#CFG_ERRS[@]} )); then
            menu_show_errors
            printf '템플릿에서 vmt-nodes로 목록을 고친다. 오류가 없는 노드는 그대로 고를 수 있다\n'
        fi
    else
        vmt_cfg_reset
    fi
    while :; do
        printf '\n== vmt-reid %s · %s %s ==\n' "$VMT_VERSION" "$VMT_OS_ID" "$VMT_OS_VERSION"
        printf '템플릿     %s (NAT %s)\n' "$VMT_TPL_HOST" "$VMT_TPL_IFACE"
        printf 'NIC        %s\n' "$(vmt_nic_inventory)"
        printf '디스크     %s\n' "$(vmt_disk_inventory)"
        printf '노드 목록  %s\n' "$( [[ -f $VMT_NODES_CONF ]] && printf '%s' "$VMT_NODES_CONF" || printf '없음')"
        menu_list_nodes
        printf '  n) 새 노드   q) 끝내기\n'
        menu_read ch "적용할 노드: "
        case $ch in
            q) vmt_say "아무것도 바꾸지 않았다"; exit 0 ;;
            n) menu_new_node n; menu_node_edit "$n" ;;
            "") continue ;;
            *)
                if ! menu_pick_node n "$ch"; then
                    printf '  ! 목록에 없는 선택이다: %s\n' "$ch"
                    continue
                fi
                ;;
        esac
        if menu_reid_plan "$n"; then
            REID_NODE=$n
            return 0
        fi
    done
}

# 노드의 적용 계획을 보여 준다. 적용(a)을 고르면 0, 뒤로(b)를 고르면 1을 돌려준다.
# 계획은 하위 셸에서 만든다. 맞지 않는 점(vmt_die)이 있어도 메뉴가 끝나지 않게 하기 위해서다
menu_reid_plan() {  # 노드
    local n=$1 ch out ok
    while :; do
        CFG_ERRS=()
        CFG_FILE=""
        vmt_cfg_validate_node "$n"
        printf '\n'
        if (( ${#CFG_ERRS[@]} )); then
            menu_show_errors
            ok=0
        elif out=$( (vmt_plan_build "$n" && vmt_plan_print) 2>&1 ); then
            printf '%s\n' "$out"
            ok=1
        else
            printf '%s\n' "$out"
            printf '이 VM에 맞지 않는 점이 있다. 노드를 고치거나 호스트에서 NIC·디스크 구성을 확인한다\n'
            ok=0
        fi
        if (( ok )); then
            printf '  a) 적용   e) 고치기   b) 뒤로\n'
        else
            printf '  e) 고치기   b) 뒤로\n'
        fi
        menu_read ch "선택: "
        case $ch in
            a) (( ok )) && return 0
               printf '  ! 적용할 수 없는 계획이다\n' ;;
            e) menu_node_edit "$n" ;;
            b) return 1 ;;
            *) printf '  ! 목록에 없는 선택이다: %s\n' "$ch" ;;
        esac
    done
}

# ── vmt-nodes 메뉴 ──────────────────────────────────────────────────────────
vmt_nodes_menu() {  # 파일
    local f=$1 ch n
    MENU_CONTEXT=nodes
    MENU_DIRTY=0
    if [[ -f $f ]]; then
        vmt_cfg_load "$f"
        vmt_cfg_validate
        if (( ${#CFG_ERRS[@]} )); then
            menu_show_errors
            printf '형식 오류가 있는 줄의 값은 메뉴에 보이지 않고, 저장하면 사라진다\n'
            menu_yes "그래도 메뉴로 고칠까? 아니면 끝내고 파일을 직접 고친다" || exit 1
        fi
    else
        vmt_cfg_reset
    fi
    CFG_FILE=""
    while :; do
        printf '\n== vmt-nodes %s · %s%s ==\n' "$VMT_VERSION" "$f" "$( (( MENU_DIRTY )) && printf ' (저장 안 함)')"
        menu_list_nodes
        printf '  c) 공통값   n) 새 노드   x) 노드 지우기   s) 저장   q) 끝내기\n'
        menu_read ch "선택: "
        case $ch in
            c) menu_defaults_edit ;;
            n) menu_new_node n; menu_node_edit "$n" ;;
            x)
                menu_read ch "  지울 노드 번호: "
                if menu_pick_node n "$ch"; then
                    vmt_cfg_remove_node "$n"
                    MENU_DIRTY=1
                    printf '  지웠다: %s\n' "$n"
                else
                    printf '  ! 목록에 없는 번호다: %s\n' "$ch"
                fi
                ;;
            s) menu_nodes_save "$f" ;;
            q)
                if (( MENU_DIRTY )) && ! menu_yes "저장하지 않은 변경이 있다. 버리고 끝낼까?"; then
                    continue
                fi
                return 0
                ;;
            "") ;;
            *)
                if menu_pick_node n "$ch"; then
                    menu_node_edit "$n"
                else
                    printf '  ! 목록에 없는 선택이다: %s\n' "$ch"
                fi
                ;;
        esac
    done
}

menu_nodes_save() {  # 파일
    CFG_ERRS=()
    CFG_FILE=""
    vmt_cfg_validate
    if (( ${#CFG_ERRS[@]} )); then
        menu_show_errors
        printf '저장하지 않았다. 오류를 고친 뒤 다시 저장한다\n'
        return 0
    fi
    vmt_cfg_save "$1"
    MENU_DIRTY=0
    printf '저장했다: %s%s\n' "$1" "$( [[ -f $1.bak ]] && printf ' (이전 파일: %s.bak)' "$1")"
}
