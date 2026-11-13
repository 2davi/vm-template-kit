# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vm-template-kit 공통 함수
#
# 이 파일은 단독으로 실행하지 않는다. tools/build.sh가 src/lib/의 파일과 OS별 파일을 이어 붙여
# dist/<os>/<버전>/vmt-clean, vmt-reid, vmt-nodes 단일 파일을 만든다.
#
# 전제
#   템플릿은 NAT NIC 하나(DHCP)로 만든다. 다른 NIC와 그 주소는 템플릿에 두지 않는다.
#   복제본을 만들 때 호스트에서 NIC와 디스크를 붙이고, vmt-reid가 노드 구성대로 설정 파일을 새로 만든다.
#
# OS별 파일이 정의하는 함수와 변수
#   os_require             OS와 버전을 확인한다. 맞지 않으면 vmt_die
#   VMT_NET_CONF           os_write_network가 만드는 설정 파일 경로
#   os_write_network       노드 구성의 NIC 설정을 만든다. 값은 P_NICS, P_IF, P_MAC과 pn 함수로 읽는다
#   os_network_present     (선택) vmt-reid가 만든 NIC 설정이 있으면 위치를 출력하고 0을 돌려준다
#   os_net_desc            (선택) 결과에 보여 줄 설정 파일 설명. 기본은 VMT_NET_CONF
#   os_template_mac        (선택) 템플릿 판별에 쓸 MAC. 기본은 NAT 인터페이스의 MAC
#   os_clean_checks        (선택) vmt-clean 사전 점검. 실패 시 vmt_die
#   os_clean_extra         (선택) vmt-clean의 OS별 정리
#   os_cfg_validate_node   (선택) 노드 구성의 OS별 규칙 검사. 오류는 cfg_err_at으로 남긴다
#   os_reid_checks         (선택) vmt-reid 사전 점검. 아무것도 바꾸기 전에 실행한다
#   os_after_net_edit      (선택) 설정 파일을 쓴 뒤 실행할 처리(문법 검사, SELinux 라벨 등)
#   os_after_mount         (선택) 추가 디스크를 마운트한 뒤 실행할 처리. 인자: 마운트 경로
#   os_ssh_hostkeys        (선택) SSH 호스트 키 재생성. 기본은 vmt_regen_ssh_hostkeys
#   os_reset_dhcp          (선택) DHCP 클라이언트 상태 초기화
#   os_reid_finish         (선택) vmt-reid 마지막 처리(SELinux 라벨 정리 등)
#   os_reid_complete       (선택) 기록과 결과 출력. 기본은 완료 기록을 남기고 재부팅을 안내한다
#   os_reid_stage2         (선택) vmt-reid --finish로 실행할 2단계(PVE)
# ─────────────────────────────────────────────────────────────────────────────

VMT_VERSION="@VMT_VERSION@"
VMT_ETC=/etc/vmt
VMT_STATE=/var/lib/vmt
VMT_TEMPLATE_ENV=$VMT_ETC/template.env   # vmt-clean이 템플릿 정보를 기록하는 파일
VMT_TEMPLATE_SCHEMA=2                    # template.env 형식 번호. 형식이 바뀌면 올린다
VMT_REID_STAMP=$VMT_ETC/reid.done        # vmt-reid가 끝났다는 기록. 있으면 다시 실행하지 않는다
VMT_BACKUP=$VMT_STATE/reid-backup        # vmt-reid가 고치기 전 원본. 처음 실행할 때만 보관한다
PROG=${0##*/}

# ── 출력 ────────────────────────────────────────────────────────────────────
vmt_die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
vmt_warn() { printf '%s: 경고: %s\n' "$PROG" "$*" >&2; }
vmt_say()  { printf '%s\n' "$*"; }

# ── 실행 환경 확인 ──────────────────────────────────────────────────────────
# 안내에는 실행한 경로($0)를 그대로 쓴다. Rocky의 sudo는 /usr/local/sbin을 찾지 않아 전체 경로가 필요하다
vmt_require_root() {
    [[ $EUID -eq 0 ]] || vmt_die "root 권한이 필요하다. sudo $0 ... 로 실행한다"
}

vmt_require_ip() {
    command -v ip >/dev/null || vmt_die "ip 명령이 없다(iproute2)"
}

# /etc/os-release의 ID와 VERSION_ID를 확인한다.
# 버전은 디렉터리 단위로 비교한다. 기대값 "9"는 9.4, 9.6을 통과시키고 10.2는 거부한다.
vmt_require_os() {
    local want_id=$1 want_ver=$2 id ver
    [[ -r /etc/os-release ]] || vmt_die "/etc/os-release를 읽지 못했다"
    # shellcheck source=/dev/null
    id=$(. /etc/os-release; printf '%s' "${ID:-}")
    # shellcheck source=/dev/null
    ver=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
    if [[ $id != "$want_id" ]] || [[ $ver != "$want_ver" && $ver != "$want_ver".* ]]; then
        vmt_die "이 스크립트는 $want_id $want_ver 전용이다. 현재 시스템: ${id:-알 수 없음} ${ver:-알 수 없음}"
    fi
    VMT_OS_ID=$id
    VMT_OS_VERSION=$ver
}

# ── 값 검사 ─────────────────────────────────────────────────────────────────
# RFC 1123 레이블: 소문자로 시작하고 소문자, 숫자, 하이픈만 쓰며 63자 이하다
vmt_valid_hostname() {
    [[ $1 =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# FQDN: 첫 레이블은 호스트명 규칙을 따르고, 나머지 레이블은 숫자로 시작해도 된다. 전체 253자 이하
vmt_valid_fqdn() {
    local fqdn=$1 label
    local -a labels
    (( ${#fqdn} <= 253 )) || return 1
    [[ $fqdn == *.* ]] || return 1
    vmt_valid_hostname "${fqdn%%.*}" || return 1
    IFS=. read -r -a labels <<<"${fqdn#*.}"
    (( ${#labels[@]} > 0 )) || return 1
    for label in "${labels[@]}"; do
        [[ $label =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
    done
}

# IPv4 주소/접두 길이 형식. 각 옥텟 0~255, 접두 1~32
vmt_valid_cidr() {
    local cidr=$1 pfx octet
    local -a octets
    [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    pfx=${cidr#*/}
    (( 10#$pfx >= 1 && 10#$pfx <= 32 )) || return 1
    IFS=. read -r -a octets <<<"${cidr%/*}"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

vmt_ip2int() {
    local -a o
    IFS=. read -r -a o <<<"$1"
    printf '%d' $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# 호스트에 붙일 수 있는 주소인지 본다. 루프백, 멀티캐스트 이상, 0.x 대역과
# 접두 30 이하에서 네트워크 주소(호스트 부분 0)와 브로드캐스트 주소(호스트 부분 모두 1)를 거부한다
vmt_usable_host_cidr() {
    local ip=${1%/*} pfx=$((10#${1#*/})) first n mask
    first=$((10#${ip%%.*}))
    (( first >= 1 && first <= 223 && first != 127 )) || return 1
    if (( pfx <= 30 )); then
        n=$(vmt_ip2int "$ip")
        mask=$(( (1 << (32 - pfx)) - 1 ))
        (( (n & mask) != 0 && (n & mask) != mask )) || return 1
    fi
}

# 두 IP/접두의 대역이 겹치면 0을 돌려준다. 짧은 쪽 접두로 두 주소의 네트워크 부분을 비교한다
vmt_cidr_overlap() {
    local a=$1 b=$2 p ia ib mask
    p=$(( 10#${a#*/} < 10#${b#*/} ? 10#${a#*/} : 10#${b#*/} ))
    ia=$(vmt_ip2int "${a%/*}")
    ib=$(vmt_ip2int "${b%/*}")
    mask=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
    (( (ia & mask) == (ib & mask) ))
}

# 정규식에서 점을 문자 그대로 읽도록 바꾼다 (호스트명과 FQDN에만 쓴다)
vmt_re_escape() {
    printf '%s' "${1//./\\.}"
}

# ── /etc/hosts ──────────────────────────────────────────────────────────────
# 짧은 호스트명이 있는 줄에서 "<호스트명>."으로 시작하는 이름(FQDN)을 찾는다. 없으면 빈 값이다
vmt_hosts_fqdn() {  # 파일, 짧은 호스트명
    awk -v h="$2" '
        /^[[:space:]]*(#|$)/ { next }
        {
            hit = 0; fq = ""
            for (i = 2; i <= NF && $i !~ /^#/; i++) {
                if ($i == h) hit = 1
                if (index($i, h ".") == 1) fq = $i
            }
            if (hit && fq != "") { print fq; exit }
        }' "$1"
}

# 새 이름, 새 IP와 맞지 않는 줄을 출력한다. 템플릿 이름이 있는 줄은 vmt-reid가 바꾸므로 보지 않는다.
#   - 새 이름(짧은 이름이나 FQDN)이 다른 IP로 있는 줄
#   - 새 IP가 새 이름 없이 있는 줄
# 템플릿에 실습 노드 목록을 미리 적어 둔 경우(같은 IP, 같은 이름)는 통과한다
vmt_hosts_conflicts() {  # 파일
    awk -v h="$NEW_HOST" -v f="$NEW_FQDN" -v ip="$NEW_IP" -v oh="$VMT_TPL_HOST" -v of="$VMT_TPL_FQDN" '
        /^[[:space:]]*(#|$)/ { next }
        {
            mine = 0; tpl = 0
            for (i = 2; i <= NF && $i !~ /^#/; i++) {
                if ($i == h || (f != "" && $i == f)) mine = 1
                if ($i == oh || (of != "" && $i == of)) tpl = 1
            }
            if (tpl) next
            if ((mine && $1 != ip) || (!mine && $1 == ip)) print
        }' "$1"
}

# /etc/hosts 새 내용을 출력한다. 인자: 원본 파일, 템플릿 이름, 템플릿 FQDN(없으면 빈 값), 새 IP, 새 이름, 새 줄
# - 템플릿 이름이 있는 줄 가운데 localhost 줄은 템플릿 이름만 뺀다. 이름이 하나도 남지 않으면 줄을 지운다
# - 나머지 줄(Debian 계열의 127.0.1.1 줄, PVE의 노드 IP 줄)은 처음 것을 새 줄로 바꾸고 이후 것은 지운다
# - 바꿀 줄이 없으면(Rocky) 새 줄을 끝에 더한다
# - 새 IP와 새 이름이 이미 한 줄에 있으면(실습 노드 목록) 새 줄을 넣지 않고 템플릿 줄만 지운다
vmt_hosts_render() {
    awk -v oh="$2" -v of="$3" -v ip="$4" -v nh="$5" -v line="$6" '
        function is_tpl(x) { return x == oh || (of != "" && x == of) }
        NR == FNR {
            if ($1 == ip) for (i = 2; i <= NF && $i !~ /^#/; i++) if ($i == nh) have = 1
            next
        }
        /^[[:space:]]*(#|$)/ { print; next }
        {
            tpl = 0
            loc = ($1 == "127.0.0.1" || $1 == "::1")
            for (i = 2; i <= NF && $i !~ /^#/; i++) {
                if (is_tpl($i)) tpl = 1
                if ($i ~ /^localhost/ || $i ~ /^ip6-(localhost|loopback)$/) loc = 1
            }
            if (!tpl) { print; next }
            if (loc) {
                out = $1; names = 0; cmt = 0
                for (i = 2; i <= NF; i++) {
                    if ($i ~ /^#/) cmt = 1
                    if (!cmt && is_tpl($i)) continue
                    if (!cmt) names++
                    out = out "\t" $i
                }
                if (names) print out
                next
            }
            if (!have && !done) { print line; done = 1 }
        }
        END { if (!have && !done) print line }' "$1" "$1"
}

# ── 파일 다루기 ─────────────────────────────────────────────────────────────
# 고치기 전 원본을 VMT_BACKUP 아래 같은 경로로 한 번만 보관한다.
# 이미 보관본이 있으면 덮어쓰지 않는다. 중간에 실패한 뒤 다시 실행해도 처음 원본이 남는다.
vmt_backup_once() {
    local f
    for f in "$@"; do
        [[ -e $f ]] || continue
        [[ -e $VMT_BACKUP$f ]] && continue
        mkdir -p "$VMT_BACKUP${f%/*}"
        cp -a "$f" "$VMT_BACKUP$f"
    done
}

# 보관본이 있으면 보관본 경로를, 없으면 원래 경로를 출력한다.
# 고칠 내용은 항상 처음 원본에서 다시 만든다. 그래서 같은 명령을 다시 실행해도 결과가 같다.
vmt_orig() {
    if [[ -e $VMT_BACKUP$1 ]]; then printf '%s' "$VMT_BACKUP$1"; else printf '%s' "$1"; fi
}

# 임시 파일 내용으로 대상 파일을 덮어쓴다. inode를 유지해 권한, 소유자, SELinux 라벨을 보존한다
vmt_overwrite() {
    cat "$1" > "$2"
    rm -f "$1"
}

# 임시 파일을 새 설정 파일로 설치한다. 다시 실행하면 처음부터 다시 쓴다
vmt_install_file() {  # 임시 파일, 대상, 권한
    mkdir -p "${2%/*}"
    install -m "$3" -o root -g root "$1" "$2"
    rm -f "$1"
}

# ── 인터페이스 ──────────────────────────────────────────────────────────────
# 기본 경로를 가진 인터페이스 이름을 한 줄에 하나씩 출력한다
vmt_default_ifaces() {
    ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' | sort -u
}

# 인터페이스의 첫 IPv4 주소/접두. 없으면 빈 값이다
vmt_iface_cidr() {
    ip -o -4 addr show | awk -v ifc="$1" '$2 == ifc { print $4; exit }'
}

# 물리 NIC인지 본다. /sys/class/net/<이름>/device가 있으면 물리 NIC다(PCI, VMBus).
# 브리지, 본드, VLAN, 루프백에는 device가 없다
vmt_is_physical() {
    [[ -e /sys/class/net/$1/device ]]
}

# 물리 NIC 이름을 출력한다. 브리지나 본드의 포트(master가 있는 NIC)는 뺀다
vmt_physical_nics() {
    local d
    for d in /sys/class/net/*; do
        vmt_is_physical "${d##*/}" || continue
        [[ -e $d/master ]] && continue
        printf '%s\n' "${d##*/}"
    done
    return 0
}

vmt_mac_of() {
    cat "/sys/class/net/$1/address" 2>/dev/null || true
}

# 주어진 MAC을 가진 인터페이스가 있으면 그 이름을 출력하고 0을 돌려준다.
# 인터페이스 이름이 템플릿과 달라도(enp0s3, eth0) MAC만으로 판별한다.
vmt_iface_with_mac() {
    local f
    for f in /sys/class/net/*/address; do
        [[ -r $f ]] || continue
        if [[ $(<"$f") == "$1" ]]; then
            f=${f%/address}
            printf '%s\n' "${f##*/}"
            return 0
        fi
    done
    return 1
}

# ── 식별 정보 ───────────────────────────────────────────────────────────────
# 첫 부팅 처리가 끝나기 전에는 systemd가 임시 machine-id 파일을 /etc/machine-id 위에 마운트해 둔다.
# 마운트 지점은 지울 수 없어 machine-id 재생성이 중간에 실패하므로, 아무것도 바꾸기 전에 거부한다
vmt_require_machine_id_file() {
    if mountpoint -q /etc/machine-id; then
        vmt_die "/etc/machine-id가 마운트 지점이다. 첫 부팅 처리가 끝나지 않은 상태에서는 고치지 않는다"
    fi
}

# machine-id를 새로 만든다.
# systemd-machine-id-setup은 /etc/machine-id가 없으면 /run/machine-id를 먼저 보고,
# 그다음 링크가 아닌 /var/lib/dbus/machine-id에서 값을 가져온다. 둘 다 지운 뒤 만든다.
vmt_regen_machine_id() {
    vmt_require_machine_id_file
    VMT_OLD_MID=$(cat /etc/machine-id 2>/dev/null || true)
    rm -f /etc/machine-id /run/machine-id
    [[ -L /var/lib/dbus/machine-id ]] || rm -f /var/lib/dbus/machine-id
    systemd-machine-id-setup >/dev/null 2>&1 || vmt_die "systemd-machine-id-setup 실패"
    VMT_NEW_MID=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $VMT_NEW_MID && $VMT_NEW_MID != "$VMT_OLD_MID" ]] || vmt_die "machine-id가 바뀌지 않았다"
    # D-Bus 쪽 파일은 /etc/machine-id를 가리키는 링크로 둔다
    if [[ -d /var/lib/dbus && ! -e /var/lib/dbus/machine-id && ! -L /var/lib/dbus/machine-id ]]; then
        ln -s /etc/machine-id /var/lib/dbus/machine-id
    fi
}

# SSH 호스트 키를 지우고 바로 다시 만든다. 키가 없는 채로 재부팅하면 sshd가 뜨지 않는 배포판이 있다
vmt_regen_ssh_hostkeys() {
    rm -f /etc/ssh/ssh_host_*
    ssh-keygen -A >/dev/null 2>&1 || vmt_die "ssh-keygen -A 실패"
    compgen -G '/etc/ssh/ssh_host_*_key' >/dev/null || vmt_die "SSH 호스트 키가 만들어지지 않았다"
}

# ── 템플릿 기록 ─────────────────────────────────────────────────────────────
vmt_template_env_write() {
    local tmp=$VMT_TEMPLATE_ENV.tmp
    mkdir -p "$VMT_ETC"
    {
        printf '# vmt-clean %s가 템플릿에서 기록한 값이다. vmt-reid가 읽는다. 손으로 고치지 않는다\n' "$VMT_VERSION"
        printf 'VMT_TPL_SCHEMA=%q\n'   "$VMT_TEMPLATE_SCHEMA"
        printf 'VMT_TPL_HOST=%q\n'     "$TPL_HOST"
        printf 'VMT_TPL_FQDN=%q\n'     "$TPL_FQDN"
        printf 'VMT_TPL_IFACE=%q\n'    "$TPL_IFACE"
        printf 'VMT_TPL_CIDR=%q\n'     "$TPL_CIDR"
        printf 'VMT_TPL_MAC=%q\n'      "$TPL_MAC"
        printf 'VMT_TPL_OS=%q\n'       "$VMT_OS_ID $VMT_OS_VERSION"
        printf 'VMT_TPL_CLEANED=%q\n'  "$(date -Is)"
        printf 'VMT_TPL_VERSION=%q\n'  "$VMT_VERSION"
    } > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$VMT_TEMPLATE_ENV"
}

vmt_template_env_load() {
    [[ -f $VMT_TEMPLATE_ENV ]] \
        || vmt_die "템플릿 기록($VMT_TEMPLATE_ENV)이 없다. 템플릿에서 vmt-clean을 실행한 뒤 스냅샷이나 부모 디스크를 다시 만든다"
    # shellcheck source=/dev/null
    . "$VMT_TEMPLATE_ENV"
    [[ ${VMT_TPL_SCHEMA:-} == "$VMT_TEMPLATE_SCHEMA" ]] \
        || vmt_die "템플릿 기록 형식이 이 버전과 다르다(${VMT_TPL_SCHEMA:-없음}, 기대 $VMT_TEMPLATE_SCHEMA). 이 버전의 vmt-clean으로 템플릿을 다시 정리한다"
    local k
    for k in VMT_TPL_HOST VMT_TPL_IFACE VMT_TPL_MAC; do
        [[ -n ${!k:-} ]] || vmt_die "템플릿 기록에 $k 값이 없다: $VMT_TEMPLATE_ENV"
    done
    VMT_TPL_FQDN=${VMT_TPL_FQDN:-}
    VMT_TPL_CIDR=${VMT_TPL_CIDR:-}
}

# ── 기본 훅 ─────────────────────────────────────────────────────────────────
# OS별 파일이 같은 이름으로 다시 정의하면 그쪽이 쓰인다(뒤에 정의한 함수가 이긴다).
os_write_network()     { vmt_die "이 OS의 os_write_network가 정의되지 않았다"; }
os_network_present()   { [[ -e $VMT_NET_CONF ]] && printf '%s\n' "$VMT_NET_CONF"; }
os_net_desc()          { if (( ${#P_NICS[@]} )); then printf '%s' "$VMT_NET_CONF"; else printf '없음(NIC 구역이 없다)'; fi; }
os_template_mac()      { vmt_mac_of "$TPL_IFACE"; }
os_clean_checks()      { :; }
os_clean_extra()       { :; }
os_cfg_validate_node() { :; }
os_reid_checks()       { :; }
os_after_net_edit()    { :; }
os_after_mount()       { :; }
os_ssh_hostkeys()      { vmt_regen_ssh_hostkeys; }
os_reset_dhcp()        { :; }
os_reid_finish()       { :; }
os_reid_complete()     { vmt_reid_stamp; vmt_reid_summary; vmt_say "다음 순서: sudo reboot"; }
os_reid_stage2()       { vmt_reid_usage >&2; exit 2; }

VMT_RENAME_RUNTIME=1               # 1이면 실행 중인 호스트명도 바로 바꾼다. PVE는 0
VMT_GROWPART_PKG=cloud-guest-utils # growpart를 제공하는 패키지
