# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# 추가 디스크와 루트 디스크 확장 적용
#
# 추가 디스크
#   볼륨([disk])마다 GPT 파티션을 하나씩 만든다. lvm = yes면 디스크 전체를 PV 파티션 하나로 만들고
#   볼륨마다 논리 볼륨(LV)을 만든다. 크기를 적지 않은 마지막 볼륨은 남은 공간을 모두 쓴다.
#   파일 시스템 UUID로 /etc/fstab 줄을 만들고 마운트한다.
#   vmt-reid는 빈 디스크만 나눈다(plan_disk가 확인한다). 만든 결과는 $VMT_DISK_STATE/<디스크>에 기록한다.
#   다시 실행하면 기록과 구성이 같은 디스크는 다시 만들지 않고, /etc/fstab만 원본에서 다시 만든다.
# 루트 디스크 확장
#   호스트에서 복제본 디스크를 늘린 경우 growpart로 루트 파티션(LVM이면 PV 파티션)을 디스크 끝까지 늘린다.
#   LVM이면 pvresize 뒤 VG의 남은 공간 전체를 루트 LV에 더한다(lvextend -r이 파일 시스템도 늘린다).
# ─────────────────────────────────────────────────────────────────────────────

# 파티션 장치 경로. 디스크 이름이 숫자로 끝나면(nvme0n1, mmcblk0) 번호 앞에 p를 붙인다
vmt_part_path() {  # 디스크, 번호
    if [[ $1 == *[0-9] ]]; then printf '/dev/%sp%s' "$1" "$2"; else printf '/dev/%s%s' "$1" "$2"; fi
}

# 볼륨의 블록 장치 경로
vmt_vol_path() {  # 디스크, 볼륨, 파티션 번호
    local dev=$1 v=$2
    if [[ $(pd "$v" lvm) == yes ]]; then
        printf '/dev/%s/%s' "$(pd "$v" vg)" "$v"
    else
        vmt_part_path "$dev" "$3"
    fi
}

storage_mkfs() {  # 파일 시스템, 레이블, 장치
    local -a opt=(-q)
    [[ -z $2 ]] || opt+=(-L "$2")
    # 표준 입력을 닫아 확인 질문에서 멈추지 않게 한다. 기존 서명이 있으면 질문 대신 실패한다
    "mkfs.$1" "${opt[@]}" "$3" </dev/null \
        || vmt_die "mkfs.$1 $3 실패. 디스크에 남은 서명 때문이면 wipefs -a로 비운 뒤 다시 실행한다"
}

storage_create() {  # 디스크
    local dev=$1 v sz mib i=0 vg path uuid script tmp state
    local -a vols
    read -r -a vols <<<"${P_DEV_VOLS[$dev]}"
    vg=""
    [[ $(pd "${vols[0]}" lvm) != yes ]] || vg=$(pd "${vols[0]}" vg)

    # sfdisk 스크립트. 파티션 안에 남은 이전 서명은 지운다(--wipe-partitions always)
    script="label: gpt"
    if [[ -n $vg ]]; then
        script+=$'\n'"type=V, name=$vg"
    else
        for v in "${vols[@]}"; do
            sz=$(pd "$v" size)
            if [[ -n $sz ]]; then
                script+=$'\n'"size=$(vmt_size_mib "$sz")MiB, type=L, name=$v"
            else
                script+=$'\n'"type=L, name=$v"
            fi
        done
    fi
    vmt_say "디스크 $dev: 파티션을 만든다"
    printf '%s\n' "$script" | sfdisk --quiet --wipe-partitions always "/dev/$dev" \
        || vmt_die "sfdisk /dev/$dev 실패"
    udevadm settle >/dev/null 2>&1 || true

    if [[ -n $vg ]]; then
        path=$(vmt_part_path "$dev" 1)
        pvcreate -q "$path" || vmt_die "pvcreate $path 실패"
        vgcreate -q "$vg" "$path" || vmt_die "vgcreate $vg 실패"
        for v in "${vols[@]}"; do
            sz=$(pd "$v" size)
            if [[ -n $sz ]]; then
                mib=$(vmt_size_mib "$sz")
                lvcreate -q --yes -n "$v" -L "${mib}m" "$vg" || vmt_die "lvcreate $vg/$v 실패"
            else
                lvcreate -q --yes -n "$v" -l 100%FREE "$vg" || vmt_die "lvcreate $vg/$v 실패"
            fi
        done
        udevadm settle >/dev/null 2>&1 || true
    fi

    state=$(mktemp)
    {
        printf '# vmt-reid %s가 노드 %s의 추가 디스크로 만든 기록이다. 다시 실행할 때 구성을 대조한다\n' "$VMT_VERSION" "$P_NODE"
        plan_dev_text "$dev"
    } > "$state"
    for v in "${vols[@]}"; do
        i=$((i + 1))
        path=$(vmt_vol_path "$dev" "$v" "$i")
        [[ $(pd "$v" fs) != none ]] || continue
        storage_mkfs "$(pd "$v" fs)" "${CFG[disk.$P_NODE.$v.label]-}" "$path"
        uuid=$(blkid -p -s UUID -o value "$path" 2>/dev/null || true)
        [[ -n $uuid ]] || vmt_die "$path의 UUID를 읽지 못했다"
        P_UUID[$v]=$uuid
        printf 'uuid %s %s\n' "$v" "$uuid" >> "$state"
    done
    mkdir -p "$VMT_DISK_STATE"
    tmp=$VMT_DISK_STATE/$dev
    mv -f "$state" "$tmp"
    chmod 644 "$tmp"
}

# /etc/fstab을 원본에서 다시 만들고 추가 디스크 줄을 붙인다
storage_fstab() {
    local dev v fs orig tmp
    vmt_backup_once /etc/fstab
    orig=$(vmt_orig /etc/fstab)
    tmp=$(mktemp)
    {
        [[ ! -e $orig ]] || cat "$orig"
        printf '# vmt-reid %s: 노드 %s의 추가 디스크\n' "$VMT_VERSION" "$P_NODE"
        for dev in "${P_DEVS[@]}"; do
            for v in ${P_DEV_VOLS[$dev]}; do
                fs=$(pd "$v" fs)
                [[ $fs != none ]] || continue
                # ext4는 부팅 때 fsck를 2순위로 돌리고, xfs는 fsck를 쓰지 않는다
                printf 'UUID=%s\t%s\t%s\t%s\t0\t%d\n' "${P_UUID[$v]}" "$(pd "$v" mount)" "$fs" \
                    "$(pd "$v" options)" "$([[ $fs == ext4 ]] && echo 2 || echo 0)"
            done
        done
    } > "$tmp"
    vmt_overwrite "$tmp" /etc/fstab
}

storage_mount() {
    local dev v m
    systemctl daemon-reload >/dev/null 2>&1 || true
    for dev in "${P_DEVS[@]}"; do
        for v in ${P_DEV_VOLS[$dev]}; do
            m=$(pd "$v" mount)
            [[ -n $m ]] || continue
            mkdir -p "$m"
            if mountpoint -q "$m"; then continue; fi
            mount "$m" || vmt_die "$m 마운트 실패. /etc/fstab 끝의 vmt-reid 줄을 확인한다"
            os_after_mount "$m"
        done
    done
}

vmt_storage_apply() {
    local dev
    (( ${#P_DEVS[@]} )) || return 0
    for dev in "${P_DEVS[@]}"; do
        if [[ ${P_DEV_DONE[$dev]-} == 1 ]]; then
            vmt_say "디스크 $dev: 이전 실행에서 만들었다. 다시 만들지 않는다"
        else
            storage_create "$dev"
        fi
    done
    storage_fstab
    storage_mount
}

vmt_root_grow_apply() {
    local rc
    (( R_DO )) || return 0
    if (( R_GROW_PART )); then
        rc=0
        growpart "$R_DISK" "$R_PARTNUM" || rc=$?
        case $rc in
            0) ;;
            1) vmt_warn "growpart: $R_PART를 늘릴 공간이 없다" ;;
            *) vmt_die "growpart $R_DISK $R_PARTNUM 실패" ;;
        esac
        if [[ -n $R_VG ]]; then
            pvresize "$R_PART" || vmt_die "pvresize $R_PART 실패"
        elif (( rc == 0 )); then
            case $R_FS in
                ext4) resize2fs "$R_PART" || vmt_die "resize2fs $R_PART 실패" ;;
                xfs)  xfs_growfs / || vmt_die "xfs_growfs / 실패" ;;
            esac
        fi
    fi
    if [[ -n $R_VG ]] && (( $(vmt_vg_free_mib "$R_VG") > 0 )); then
        lvextend -r -l +100%FREE "$R_VG/$R_LV" || vmt_die "lvextend $R_VG/$R_LV 실패"
    fi
    return 0
}
