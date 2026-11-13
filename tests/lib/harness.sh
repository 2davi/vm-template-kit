# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# 테스트 하네스
#
# tests/lib/sandbox.sh가 마운트·UTS 네임스페이스 안에서 이 파일을 읽는다.
# /etc, /var, /root, /home, /usr/local, /usr/lib/systemd를 overlay로 덮고 /run을 tmpfs로 바꾼다.
# /sys/class/net과 /sys/block은 가짜 디렉터리로 바꾸고, 임시 파일(mktemp)은 샌드박스 안에 만든다.
# 실제 시스템은 바뀌지 않는다. 스크립트가 이 목록 밖의 경로에 쓰게 되면 SB_OVERLAYS에 그 경로를 더한다.
# 시스템을 건드리는 명령(ip, ssh-keygen, systemctl, curl, 디스크 명령 등)은 tests/stubs의 대역으로 바꾼다.
# mount도 대역이 있으므로 하네스는 command -p로 실제 mount를 부른다.
# ─────────────────────────────────────────────────────────────────────────────

SB=/tmp/vmt-sandbox
SB_OVERLAYS=(/etc /var /root /home /usr/local /usr/lib/systemd /srv)
export VMT_TEST_SB=$SB
export VMT_TEST_LOG=$SB/calls.log

sb_mount() {
    mkdir -p "$SB"
    command -p mount -t tmpfs tmpfs "$SB"
    local d n=0
    for d in "${SB_OVERLAYS[@]}"; do
        n=$((n + 1))
        mkdir -p "$SB/ov$n/up" "$SB/ov$n/wk"
        command -p mount -t overlay overlay -o "lowerdir=$d,upperdir=$SB/ov$n/up,workdir=$SB/ov$n/wk" "$d"
    done
    command -p mount -t tmpfs tmpfs /run
    mkdir -p "$SB/net" "$SB/tmp" "$SB/block" "$SB/blk"
    command -p mount --bind "$SB/net" /sys/class/net
    command -p mount --bind "$SB/block" /sys/block
    export TMPDIR=$SB/tmp
    : > "$VMT_TEST_LOG"
    : > "$SB/ip-addr"
    : > "$SB/ip-route"
}

sb_umount() {
    umount /sys/block 2>/dev/null || true
    umount /sys/class/net 2>/dev/null || true
    umount /run 2>/dev/null || true
    local i
    for (( i = ${#SB_OVERLAYS[@]} - 1; i >= 0; i-- )); do
        umount "${SB_OVERLAYS[$i]}" 2>/dev/null || true
    done
    umount "$SB" 2>/dev/null || true
}

sb_reset() { sb_umount; sb_mount; }

# ── 고정 데이터(fixture) ────────────────────────────────────────────────────
fx_file() {  # 경로, 내용
    mkdir -p "$(dirname "$1")"
    rm -f "$1"
    printf '%s\n' "$2" > "$1"
}

fx_os() {  # ID VERSION_ID
    rm -f /etc/os-release
    printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s %s (test)"\n' "$1" "$2" "$1" "$2" > /etc/os-release
}

fx_hostname() {
    printf '%s\n' "$1" > /etc/hostname
    hostname "$1"
}

# 가짜 인터페이스. 물리 NIC에는 실제 sysfs처럼 device 항목을 둔다(브리지, 본드, 루프백에는 없다)
fx_iface() {  # 이름, MAC, [IP/접두]
    mkdir -p "$SB/net/$1"
    printf '%s\n' "$2" > "$SB/net/$1/address"
    case $1 in
        vmbr*|br*|bond*|lo) ;;
        *) mkdir -p "$SB/net/$1/device" ;;
    esac
    if [[ -n ${3:-} ]]; then
        local n
        n=$(( $(wc -l < "$SB/ip-addr") + 2 ))
        printf '%s: %s    inet %s brd 0.0.0.0 scope global %s\\       valid_lft forever preferred_lft forever\n' \
            "$n" "$1" "$3" "$1" >> "$SB/ip-addr"
    fi
}

# 브리지 포트로 만든다. 실제 sysfs의 master 링크 대신 파일을 둔다
fx_port() {  # 포트, 브리지
    printf '%s\n' "$2" > "$SB/net/$1/master"
}

# 기본 경로. ip 대역이 "ip -4 route show default"에 이 내용을 출력한다
fx_route() {  # 인터페이스, [게이트웨이]
    printf 'default via %s dev %s proto dhcp metric 100\n' "${2:-10.0.2.2}" "$1" >> "$SB/ip-route"
}

# 복제를 흉내 낸다. 디스크(파일)는 그대로 두고 모든 인터페이스의 MAC만 새로 만든다.
# 관리망 NIC는 호스트에서 복제본에 붙이므로 케이스 파일이 fx_iface로 따로 더한다
fx_clone() {
    local f i=0
    for f in "$SB"/net/*/address; do
        i=$((i + 1))
        printf '0a:bb:cc:dd:%02x:%02x\n' "$((RANDOM % 256))" "$i" > "$f"
    done
}

fx_machine_id() {
    rm -f /etc/machine-id
    printf '%s\n' "$1" > /etc/machine-id
    mkdir -p /var/lib/dbus
    rm -f /var/lib/dbus/machine-id
    ln -s /etc/machine-id /var/lib/dbus/machine-id
}

fx_ssh_keys() {
    mkdir -p /etc/ssh
    rm -f /etc/ssh/ssh_host_*
    local t
    for t in rsa ecdsa ed25519; do
        printf 'TEMPLATE-%s-PRIVATE\n' "$t" > "/etc/ssh/ssh_host_${t}_key"
        printf 'ssh-%s TEMPLATE-%s-PUBLIC root@tpl\n' "$t" "$t" > "/etc/ssh/ssh_host_${t}_key.pub"
    done
}

fx_systemd_state() {
    mkdir -p /var/lib/systemd
    printf 'seed\n'   > /var/lib/systemd/random-seed
    printf 'secret\n' > /var/lib/systemd/credential.secret
}

fx_active_units() { printf '%s\n' "$@" > "$SB/active-units"; }

# 가짜 디스크: /sys/block/<이름>/size(512바이트 섹터 수)와 ro. 파티션 수를 주면 파티션과 GPT 서명도 둔다
fx_disk() {  # 이름, 크기(MiB), [파티션 수]
    local i
    mkdir -p "$SB/block/$1"
    printf '%d\n' $(( $2 * 2048 )) > "$SB/block/$1/size"
    printf '0\n' > "$SB/block/$1/ro"
    for (( i = 1; i <= ${3:-0}; i++ )); do
        mkdir -p "$SB/block/$1/$1$i"
    done
    if (( ${3:-0} > 0 )); then printf 'PTTYPE=gpt\n' > "$SB/blk/$1.sig"; fi
}

# 디스크에 남은 서명(blkid 대역이 출력한다)
fx_disk_sig() { printf '%s\n' "$2" > "$SB/blk/$1.sig"; }   # 디스크, 서명(예: TYPE=ext4)

# 루트 파일 시스템(findmnt 대역이 출력한다)과 LVM 구성(vgs, lvs, pvs 대역이 읽는다)
fx_root() { printf '%s %s\n' "$1" "$2" > "$SB/root-mount"; }        # 장치, 파일 시스템 종류
fx_vg()   { printf '%s %s %s\n' "$1" "$2" "${3:-$2}" >> "$SB/vgs"; } # VG, 남은 MiB, pvresize 뒤 남은 MiB
fx_lv()   { printf '%s %s %s\n' "$1" "$2" "$3" >> "$SB/lvs"; }       # 장치, VG, LV
fx_pv()   { printf '%s %s\n' "$1" "$2" >> "$SB/pvs"; }               # PV, VG
fx_growpart_rc() { printf '%s\n' "$1" > "$SB/growpart-rc"; }         # 0 늘릴 수 있음, 1 공간 없음, 2 오류

# ── 실행과 검사 ─────────────────────────────────────────────────────────────
T_OUT=""
T_RC=0
run() {
    T_OUT=$("$@" 2>&1)
    T_RC=$?
}

t_fail() {
    printf '      FAIL: %s\n' "$*"
    # shellcheck disable=SC2034  # tests/lib/sandbox.sh가 테스트 종료 코드로 읽는다
    T_FAILED=1
}

assert_rc()        { [[ $T_RC -eq $1 ]] || t_fail "종료 코드 기대 $1, 실제 $T_RC"$'\n'"$T_OUT"; }
assert_out()       { grep -Fq -- "$1" <<<"$T_OUT" || t_fail "출력에 '$1' 없음"$'\n'"$T_OUT"; }
assert_not_out()   { ! grep -Fq -- "$1" <<<"$T_OUT" || t_fail "출력에 '$1'이 있으면 안 된다"$'\n'"$T_OUT"; }
assert_eq()        { [[ $1 == "$2" ]] || t_fail "${3:-값}: 기대 '$2', 실제 '$1'"; }
assert_ne()        { [[ $1 != "$2" ]] || t_fail "${3:-값}: '$1'과 달라야 한다"; }
assert_line()      { grep -qxF -- "$2" "$1" 2>/dev/null || t_fail "$1에 줄 없음: $2"; }
assert_grep()      { grep -Eq -- "$2" "$1" 2>/dev/null || t_fail "$1에 패턴 없음: $2"; }
assert_no_grep()   { ! grep -Eq -- "$2" "$1" 2>/dev/null || t_fail "$1에 있으면 안 되는 패턴: $2"; }
assert_exists()    { [[ -e $1 || -L $1 ]] || t_fail "있어야 한다: $1"; }
assert_missing()   { [[ ! -e $1 && ! -L $1 ]] || t_fail "없어야 한다: $1"; }
assert_called()    { grep -Fq -- "$1" "$VMT_TEST_LOG" || t_fail "호출 기록 없음: $1"; }
assert_not_called(){ ! grep -Fq -- "$1" "$VMT_TEST_LOG" || t_fail "호출되면 안 된다: $1"; }
tpl_env()          { ( . /etc/vmt/template.env; eval "printf '%s' \"\${$1}\"" ); }
