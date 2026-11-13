# shellcheck shell=bash
# 노드 구성(nodes.conf): 읽기와 검사, 여러 NIC, 추가 디스크, 루트 확장, 메뉴, vmt-nodes, vmt-clean 연동.
# OS별 차이가 없는 처리라 Ubuntu 26.04 생성 파일로 검사한다. OS별 설정 파일 형식은 OS별 케이스에서 본다.
CLEAN="$ROOT/dist/ubuntu/26.04/vmt-clean"
REID="$ROOT/dist/ubuntu/26.04/vmt-reid"
NODES="$ROOT/dist/ubuntu/26.04/vmt-nodes"
CONF=/etc/vmt/nodes.conf
NP=/etc/netplan/60-vmt.yaml
MAC1=0a:00:27:ee:00:02
MAC2=0a:00:27:ee:00:03
TPL_MID=11111111111111111111111111111111

setup() {
    rm -rf /etc/netplan /etc/cloud /etc/vmt /var/lib/vmt /srv/*
    mkdir -p /etc/vmt
    fx_os ubuntu 26.04
    fx_hostname ubuntu-tpl
    fx_file /etc/hosts "127.0.0.1 localhost
127.0.1.1 ubuntu-tpl.lab.internal ubuntu-tpl"
    fx_file /etc/netplan/50-cloud-init.yaml "network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true"
    chmod 600 /etc/netplan/50-cloud-init.yaml
    fx_file /etc/fstab "/dev/disk/by-uuid/root-uuid / ext4 defaults 0 1"
    fx_iface enp0s3 08:00:27:aa:00:01 10.0.2.15/24
    fx_route enp0s3
    fx_machine_id "$TPL_MID"
    fx_ssh_keys
    fx_systemd_state
    fx_disk sda 20480 2
}

# 노드 목록 두 개짜리. db-01은 NIC 둘, 디스크 볼륨 둘, 루트 확장을 쓴다
write_conf() {
    fx_file "$CONF" "[defaults]
domain = lab.internal
dns = 192.168.56.1
search = lab.internal

[node web-01]

[nic mgmt]
address = 192.168.56.11/24

[node db-01]
hostname = db-01.db.internal
root_grow = yes

[nic mgmt]
interface = mac:$MAC1
address = 192.168.56.21/24, 192.168.56.22/24
gateway = 192.168.56.1
routes = 10.20.0.0/16 via 192.168.56.254
mtu = 9000

[nic data]
interface = mac:$MAC2
method = dhcp

[disk pg]
device = sdb
size = 30G
fs = xfs
mount = /srv/pg

[disk wal]
device = sdb
mount = /srv/wal"
}

# 템플릿 정리, 복제(MAC 변경), NIC 둘과 디스크 하나 추가
clone() {
    bash "$CLEAN" >/dev/null 2>&1 || true
    fx_clone
    fx_iface enp0s8 "$MAC1"
    fx_iface enp0s9 "$MAC2"
    fx_disk sdb 40960
}

# 템플릿 정리, 복제, NIC 하나(enp0s8)만 추가
clone_one() {
    bash "$CLEAN" >/dev/null 2>&1 || true
    fx_clone
    fx_iface enp0s8 "$MAC1"
}

input() { printf "$@" > "$VMT_TEST_SB/in"; }

# ── 읽기와 검사 ─────────────────────────────────────────────────────────────
test_nodes_check_example() {
    cp "$ROOT/dist/nodes.conf.example" "$CONF"
    run bash "$NODES" --check
    assert_rc 0
    assert_out "$CONF: 오류 없음, 노드 2개"
    assert_out "web-01           web-01  NIC 1 (192.168.56.11/24), 디스크 0"
    assert_out "db-01            db-01  NIC 2 (192.168.56.21/24), 디스크 3"
}

test_nodes_check_reports_all_errors_with_lines() {
    fx_file "$CONF" "[defaults]
colour = blue
[nic early]
[node Bad_Name]
dns = 1.2.3.4
[node ok-01]
dns = 300.1.1.1
dns = 1.1.1.1
[nic a]
address = 192.168.56.10
[nic b]
interface = auto
method = static
[nic c]
gateway = 10.9.9.9
address = 192.168.57.10/24
[disk d1]
device = sdb
fs = none
mount = /srv/x
[disk d2]
device = sdb
size = 10G
mount = /etc
[weird]
oops"
    run bash "$NODES" --check
    assert_rc 1
    assert_out "노드 구성에 오류가 "
    assert_out "$CONF:2: [defaults]에 쓸 수 없는 키: colour"
    assert_out "$CONF:3: [nic early]가 속할 [node]가 앞에 없다"
    assert_out "$CONF:4: 노드 이름이 맞지 않다: [node Bad_Name]"
    assert_out "$CONF:8: 키가 겹친다: dns (처음: 7번 줄)"
    assert_out "$CONF:25: 알 수 없는 구역: [weird]"
    assert_out "$CONF:26: 키 = 값 형식이 아니다: oops"
    assert_out "$CONF:7: [node ok-01] DNS 서버 주소가 맞지 않다: 300.1.1.1"
    assert_out "$CONF:10: [node ok-01] [nic a] 주소는 IP/접두 형식으로 쓴다: 192.168.56.10"
    assert_out "$CONF:11: [node ok-01] [nic b] method = static이면 address가 있어야 한다"
    assert_out "$CONF:15: [node ok-01] [nic c] gateway 10.9.9.9가 이 NIC의 대역(192.168.57.10/24) 밖에 있다"
    assert_out "$CONF:20: [node ok-01] [disk d1] fs = none에는 mount를 쓰지 않는다"
    assert_out "$CONF:17: [node ok-01] [disk d1] size가 없다. 남은 공간을 모두 쓰는 볼륨은 디스크(sdb)의 마지막 볼륨이어야 한다"
    assert_out "$CONF:24: [node ok-01] [disk d2] 마운트 경로가 맞지 않다: /etc"
    # 잘못된 [node] 머리 뒤의 키는 따로 오류를 내지 않는다
    assert_not_out ":5:"
}

test_nodes_check_cross_field_rules() {
    fx_file "$CONF" "[node n1]
[nic a]
address = 192.168.56.10/24
[nic b]
address = 192.168.56.20/24
[nic c]
method = dhcp
address = 192.168.58.1/24
[nic d]
interface = auto
method = off
routes = 10.0.0.0/8 via 192.168.56.1
[disk x]
device = sdb
lvm = yes
mount = /srv/x
size = 1G
[disk y]
device = sdb
mount = /srv/x
[disk z]
device = sdc
fs = xfs
label = longer-than-12
mount = /srv/z
[node n2]
[nic e]
interface = enp0s20
address = 192.168.70.1/24
routes = 10.9.0.0/33 via 192.168.70.254
[nic f]
interface = enp0s21
address = 192.168.71.1/24
routes = 10.8.0.1/16 via 192.168.71.254"
    run bash "$NODES" --check
    assert_rc 1
    assert_out "[node n2] [nic e] 경로는 '대상 via 게이트웨이' 형식으로 쓴다: 10.9.0.0/33 via 192.168.70.254"
    assert_out "[node n2] [nic f] 경로의 대상은 네트워크 주소로 쓴다: 10.8.0.1/16"
    assert_out "[nic b] 192.168.56.20/24가 [nic a]의 192.168.56.10/24와 대역이 겹친다"
    assert_out "[nic b] interface = auto는 노드마다 NIC 하나에만 쓴다"
    assert_out "[nic c] method = dhcp에는 address를 쓰지 않는다"
    assert_out "[nic d] method = off에는 routes를 쓰지 않는다"
    assert_out "[disk y] 같은 디스크(sdb)의 볼륨은 lvm 값이 같아야 한다"
    assert_out "[disk y] [disk x]와 마운트 경로가 같다: /srv/x"
    assert_out "[disk z] xfs의 label은 12자 이하다: longer-than-12"
}

# 따옴표, 줄 끝 주석, CRLF 줄 끝, UTF-8 BOM, 대문자 MAC, 대문자 크기 단위
test_nodes_parser_quotes_comments_crlf() {
    printf '\357\273\277[node q-01]\r\nhostname = "q-01.example.test" ; 따옴표 값\r\n  ; 들여 쓴 주석\r\n[nic m]   # 머리 뒤 주석\r\ninterface = MAC:0A:00:27:EE:00:02\r\naddress = 192.168.56.30/24 # 주석\r\nroutes = '"'"'10.1.0.0/16 via 192.168.56.1'"'"'\r\n[disk d]\r\ndevice = /dev/sdb\r\nsize = 10gib\r\nmount = /srv/d\r\n' > "$CONF"
    run bash "$NODES" --show q-01
    assert_rc 0
    assert_out "hostname = q-01.example.test"
    assert_out "interface = MAC:0A:00:27:EE:00:02"
    assert_out "address = 192.168.56.30/24"
    assert_out "routes = 10.1.0.0/16 via 192.168.56.1"
    assert_out "size = 10gib"
}

test_nodes_show_merges_defaults() {
    write_conf
    run bash "$NODES" --show web-01
    assert_rc 0
    assert_out "[node web-01]"
    assert_out "domain = lab.internal"
    assert_out "dns = 192.168.56.1"
    assert_not_out "[node db-01]"
    run bash "$NODES" --show nope
    assert_rc 1
    assert_out "노드가 없다: nope. 있는 노드: web-01 db-01"
}

# ── 적용: 여러 NIC ──────────────────────────────────────────────────────────
test_reid_node_two_nics() {
    write_conf
    clone
    fx_iface enp0s10 0a:00:27:ee:00:04
    run bash "$REID" --node db-01
    assert_rc 0
    assert_out "노드 구성에 없는 NIC가 있다: enp0s10. vmt-reid는 이 NIC의 설정을 만들지 않는다"
    assert_line /etc/hostname db-01
    assert_line /etc/hosts "192.168.56.21	db-01.db.internal	db-01"
    assert_line "$NP" '    vmt-mgmt:'
    assert_line "$NP" "        macaddress: \"$MAC1\""
    assert_line "$NP" '        - 192.168.56.21/24'
    assert_line "$NP" '        - 192.168.56.22/24'
    assert_line "$NP" '      mtu: 9000'
    assert_line "$NP" '        - to: default'
    assert_line "$NP" '          via: 192.168.56.1'
    assert_line "$NP" '          metric: 50'
    assert_line "$NP" '        - to: 10.20.0.0/16'
    assert_line "$NP" '          via: 192.168.56.254'
    assert_line "$NP" '        addresses: [192.168.56.1]'
    assert_line "$NP" '        search: [lab.internal]'
    assert_line "$NP" '    vmt-data:'
    assert_line "$NP" "        macaddress: \"$MAC2\""
    assert_line "$NP" '      dhcp4: true'
    assert_line "$NP" '        route-metric: 2000'
    # DNS는 첫 고정 주소 NIC(mgmt)에만 붙는다
    assert_eq "$(grep -c 'nameservers:' "$NP")" 1 "nameservers 수"
    assert_eq "$(stat -c %a "$NP")" 600 "netplan 파일 권한"
    assert_called "netplan generate"
    # 적용 기록
    assert_line /etc/vmt/node.conf "# [nic mgmt] -> enp0s8 (MAC $MAC1)"
    assert_line /etc/vmt/node.conf "# [nic data] -> enp0s9 (MAC $MAC2)"
    assert_line /etc/vmt/node.conf "[node db-01]"
    assert_line /etc/vmt/node.conf "dns = 192.168.56.1"
    assert_grep /etc/vmt/reid.done 'ubuntu-tpl -> db-01\.db\.internal node db-01 vmt'
    assert_out "기본 경로 192.168.56.1 (metric 50, NAT보다 앞선다)"
    assert_out "DNS          192.168.56.1, 검색 도메인 lab.internal ([nic mgmt]에 붙인다)"
}

test_reid_config_file_with_one_or_many_nodes() {
    write_conf
    clone
    run bash "$REID" --config "$CONF"
    assert_rc 1
    assert_out "노드가 2개 있다(web-01 db-01). --node로 고른다"
    fx_file /root/one.conf "[node solo-01]
[nic mgmt]
interface = enp0s8
address = 192.168.56.77/24"
    run bash "$REID" --config /root/one.conf
    assert_rc 0
    assert_line /etc/hostname solo-01
    # 도메인을 적지 않았으면 템플릿 도메인을 쓴다
    assert_line /etc/hosts "192.168.56.77	solo-01.lab.internal	solo-01"
}

test_reid_check_changes_nothing() {
    write_conf
    clone_one
    run bash "$REID" --check --node web-01
    assert_rc 0
    assert_out "== 적용 계획: 노드 web-01 =="
    assert_out "  mgmt       enp0s8 ($MAC1) 고정 192.168.56.11/24"
    assert_out "--check: 아무것도 바꾸지 않았다"
    assert_line /etc/hostname ubuntu-tpl
    assert_missing "$NP"
    assert_missing /etc/vmt/reid.done
    run bash "$REID" --check
    assert_rc 2
}

test_reid_nic_resolution_errors() {
    write_conf
    clone
    sed -i "s/interface = mac:$MAC2/interface = mac:0a:00:27:ee:00:99/" "$CONF"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[nic data] MAC 0a:00:27:ee:00:99을 가진 NIC가 없다. 이 VM의 NIC: enp0s3("
    sed -i "s/interface = mac:0a:00:27:ee:00:99/interface = enp0s3/" "$CONF"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[nic data] enp0s3는 템플릿의 NAT 인터페이스다"
    sed -i "s/interface = enp0s3/interface = enp0s8/" "$CONF"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[nic data]와 [nic mgmt]가 같은 NIC(enp0s8)를 가리킨다"
    sed -i "s/interface = enp0s8/interface = enp0s7/" "$CONF"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[nic data] 인터페이스가 없다: enp0s7"
    # auto 후보가 둘이면 고르지 않는다
    run bash "$REID" --node web-01
    assert_rc 1
    assert_out "[nic mgmt]에 쓸 NIC 후보가 여럿이다: enp0s8($MAC1), enp0s9($MAC2). interface에 이름(예: enp0s8)이나 mac:<MAC>을 적는다"
    assert_line /etc/hostname ubuntu-tpl
    assert_missing "$NP"
}

test_reid_method_off_and_node_without_nics() {
    fx_file "$CONF" "[node bare-01]

[node off-01]
[nic link]
method = off
mtu = 1500"
    clone
    run bash "$REID" --check --node bare-01
    assert_rc 0
    assert_out "NIC          없음(NAT NIC만 쓴다)"
    run bash "$REID" --node off-01
    assert_rc 1
    assert_out "[nic link]에 쓸 NIC 후보가 여럿이다"
    sed -i 's/method = off/method = off\ninterface = enp0s9/' "$CONF"
    run bash "$REID" --node off-01
    assert_rc 0
    assert_line "$NP" '      link-local: []'
    assert_line "$NP" '      mtu: 1500'
    assert_no_grep "$NP" 'addresses:'
    # 고정 주소가 없으면 /etc/hosts에는 127.0.1.1을 쓴다
    assert_line /etc/hosts "127.0.1.1	off-01.lab.internal	off-01"
}

test_reid_node_without_nics_removes_nothing_else() {
    fx_file "$CONF" "[node bare-01]"
    clone
    run bash "$REID" --node bare-01
    assert_rc 0
    assert_missing "$NP"
    assert_line /etc/hosts "127.0.1.1	bare-01.lab.internal	bare-01"
    assert_line /etc/netplan/50-cloud-init.yaml '      dhcp4: true'
}

# ── 적용: 추가 디스크 ───────────────────────────────────────────────────────
test_reid_disk_partitions() {
    write_conf
    clone
    run bash "$REID" --node db-01
    assert_rc 0
    assert_line "$VMT_TEST_SB/sfdisk-sdb" 'label: gpt'
    assert_line "$VMT_TEST_SB/sfdisk-sdb" 'size=30720MiB, type=L, name=pg'
    assert_line "$VMT_TEST_SB/sfdisk-sdb" 'type=L, name=wal'
    assert_called "sfdisk --quiet --wipe-partitions always /dev/sdb"
    assert_called "mkfs.xfs -q /dev/sdb1"
    assert_called "mkfs.ext4 -q /dev/sdb2"
    assert_line /etc/fstab "/dev/disk/by-uuid/root-uuid / ext4 defaults 0 1"
    assert_line /etc/fstab "UUID=uuid-sdb1	/srv/pg	xfs	defaults,nofail	0	0"
    assert_line /etc/fstab "UUID=uuid-sdb2	/srv/wal	ext4	defaults,nofail	0	2"
    assert_called "systemctl daemon-reload"
    assert_called "mount /srv/pg"
    assert_called "mount /srv/wal"
    [[ -d /srv/pg && -d /srv/wal ]] || t_fail "마운트 경로가 없다"
    assert_line /var/lib/vmt/disk/sdb "plan pg size=30G fs=xfs lvm=no vg= label="
    assert_line /var/lib/vmt/disk/sdb "uuid pg uuid-sdb1"
    assert_out "디스크 pg : sdb xfs /srv/pg UUID=uuid-sdb1"
}

test_reid_disk_lvm() {
    fx_file "$CONF" "[node lv-01]
[nic mgmt]
address = 192.168.56.31/24
interface = enp0s8
[disk app]
device = sdc
lvm = yes
size = 10G
mount = /srv/app
label = app
[disk logs]
device = sdc
lvm = yes
fs = xfs
mount = /srv/logs"
    clone
    fx_disk sdc 20480
    run bash "$REID" --node lv-01
    assert_rc 0
    assert_line "$VMT_TEST_SB/sfdisk-sdc" 'type=V, name=vg_sdc'
    assert_called "pvcreate -q /dev/sdc1"
    assert_called "vgcreate -q vg_sdc /dev/sdc1"
    assert_called "lvcreate -q --yes -n app -L 10240m vg_sdc"
    assert_called "lvcreate -q --yes -n logs -l 100%FREE vg_sdc"
    assert_called "mkfs.ext4 -q -L app /dev/vg_sdc/app"
    assert_called "mkfs.xfs -q /dev/vg_sdc/logs"
    assert_line /etc/fstab "UUID=uuid-vg_sdc_app	/srv/app	ext4	defaults,nofail	0	2"
    assert_line /etc/fstab "UUID=uuid-vg_sdc_logs	/srv/logs	xfs	defaults,nofail	0	0"
}

test_reid_disk_refusals() {
    write_conf
    clone
    fx_disk_sig sdb "PTTYPE=dos"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[disk pg] sdb가 비어 있지 않다(PTTYPE=dos). vmt-reid는 빈 디스크만 나눈다"
    rm -f "$VMT_TEST_SB/blk/sdb.sig"
    mkdir -p "$VMT_TEST_SB/block/sdb/sdb1"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[disk pg] sdb에 파티션이 있다"
    rm -rf "$VMT_TEST_SB/block/sdb/sdb1"
    sed -i 's/device = sdb/device = sdz/' "$CONF"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[disk pg] 디스크가 없다: sdz. 이 VM의 디스크: sda(20G, 파티션 있음), sdb(40G, 파티션 없음)"
    sed -i 's/device = sdz/device = sdb\ndisk_size = 50G/' "$CONF"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[disk pg] sdb 크기(40G)가 disk_size(50G)와 다르다"
    sed -i 's/disk_size = 50G/disk_size = 40G/; s/size = 30G/size = 41G/' "$CONF"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[disk pg] sdb 볼륨 크기 합계(41G)가 쓸 수 있는 크기(39.9G)보다 크다"
    sed -i 's/size = 41G/size = 30G/' "$CONF"
    fx_file /srv/pg/keep "data"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[disk pg] 마운트 경로 /srv/pg가 비어 있지 않다"
    # 아무것도 바꾸지 않았다
    assert_line /etc/hostname ubuntu-tpl
    assert_not_called "sfdisk"
    assert_missing "$NP"
}

# 디스크를 만든 뒤 다른 단계에서 멈췄다가 다시 실행하는 경우: 디스크는 다시 만들지 않고 fstab은 원본에서 다시 만든다
test_reid_disk_rerun_reuses_state() {
    write_conf
    clone
    run bash "$REID" --node db-01
    assert_rc 0
    rm -f /etc/vmt/reid.done
    : > "$VMT_TEST_LOG"
    run bash "$REID" --node db-01
    assert_rc 0
    assert_out "디스크 sdb: 이전 실행에서 만들었다. 다시 만들지 않는다"
    assert_not_called "sfdisk"
    assert_not_called "mkfs"
    assert_eq "$(grep -c 'uuid-sdb1' /etc/fstab)" 1 "fstab의 sdb1 줄 수"
    assert_eq "$(grep -c '^/dev/disk/by-uuid/root-uuid' /etc/fstab)" 1 "fstab 원본 줄 수"
    # 구성을 바꿔 다시 실행하면 거부한다
    rm -f /etc/vmt/reid.done
    sed -i 's/size = 30G/size = 20G/' "$CONF"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "[disk pg] sdb는 이 VM에서 다른 구성으로 이미 만들었다(/var/lib/vmt/disk/sdb)"
}

test_reid_disk_mkfs_failure_stops() {
    write_conf
    clone
    touch "$VMT_TEST_SB/mkfs-fail"
    run bash "$REID" --node db-01
    assert_rc 1
    assert_out "mkfs.xfs /dev/sdb1 실패"
    assert_missing /var/lib/vmt/disk/sdb
    assert_missing /etc/vmt/reid.done
}

# ── 루트 확장 ───────────────────────────────────────────────────────────────
root_conf() {
    fx_file "$CONF" "[defaults]
root_grow = yes
[node r-01]
[nic mgmt]
interface = enp0s8
address = 192.168.56.41/24"
}

test_root_grow_partition_ext4() {
    root_conf
    clone
    fx_growpart_rc 0
    run bash "$REID" --node r-01
    assert_rc 0
    assert_called "growpart -N /dev/sda 2"
    assert_called "growpart /dev/sda 2"
    assert_called "resize2fs /dev/sda2"
    assert_out "루트 확장    /dev/sda2 파티션과 ext4 파일 시스템을 디스크 끝까지 늘린다"
}

test_root_grow_partition_xfs() {
    root_conf
    clone
    fx_root /dev/sda2 xfs
    fx_growpart_rc 0
    run bash "$REID" --node r-01
    assert_rc 0
    assert_called "xfs_growfs /"
    assert_not_called "resize2fs"
}

test_root_grow_lvm() {
    root_conf
    clone
    fx_root /dev/mapper/ubuntu--vg-ubuntu--lv ext4
    fx_lv /dev/mapper/ubuntu--vg-ubuntu--lv ubuntu-vg ubuntu-lv
    fx_pv /dev/sda3 ubuntu-vg
    fx_vg ubuntu-vg 0 10240
    fx_growpart_rc 0
    run bash "$REID" --node r-01
    assert_rc 0
    assert_called "growpart /dev/sda 3"
    assert_called "pvresize /dev/sda3"
    assert_called "lvextend -r -l +100%FREE ubuntu-vg/ubuntu-lv"
    assert_out "/dev/sda3 파티션을 디스크 끝까지 늘리고, ubuntu-vg/ubuntu-lv와 ext4 파일 시스템을 VG의 남은 공간 전체로 늘린다"
}

# Ubuntu 설치 프로그램은 VG 일부만 루트 LV에 준다. 디스크를 늘리지 않아도 VG의 남은 공간을 쓴다
test_root_grow_lvm_free_space_only() {
    root_conf
    clone
    fx_root /dev/mapper/ubuntu--vg-ubuntu--lv ext4
    fx_lv /dev/mapper/ubuntu--vg-ubuntu--lv ubuntu-vg ubuntu-lv
    fx_pv /dev/sda3 ubuntu-vg
    fx_vg ubuntu-vg 5120
    run bash "$REID" --node r-01
    assert_rc 0
    assert_not_called "growpart /dev/sda 3"
    assert_not_called "pvresize"
    assert_called "lvextend -r -l +100%FREE ubuntu-vg/ubuntu-lv"
    assert_out "VG ubuntu-vg에 남은 5G를 ubuntu-vg/ubuntu-lv에 더하고 ext4 파일 시스템을 늘린다"
}

test_root_grow_nothing_to_do_and_errors() {
    root_conf
    clone
    run bash "$REID" --check --node r-01
    assert_rc 0
    assert_out "늘릴 공간이 없다(/dev/sda2가 이미 디스크 끝까지 쓴다)"
    fx_growpart_rc 2
    run bash "$REID" --node r-01
    assert_rc 1
    assert_out "root_grow: growpart -N /dev/sda 2 실패: FAILED: 가짜 오류. root_grow = no로 둔다"
    assert_line /etc/hostname ubuntu-tpl
    fx_root /dev/sda2 btrfs
    run bash "$REID" --node r-01
    assert_rc 1
    assert_out "root_grow: 루트 파일 시스템이 ext4나 xfs가 아니다(btrfs)"
}

# ── 메뉴 ────────────────────────────────────────────────────────────────────
test_menu_reid_pick_and_apply() {
    write_conf
    clone
    input '2\na\n'
    run bash "$REID" < "$VMT_TEST_SB/in"
    assert_rc 0
    assert_out "  1) web-01           web-01  NIC 1 (192.168.56.11/24), 디스크 0"
    assert_out "  2) db-01            db-01.db.internal  NIC 2 (192.168.56.21/24), 디스크 2"
    assert_out "== 적용 계획: 노드 db-01 =="
    assert_out "  a) 적용   e) 고치기   b) 뒤로"
    assert_out "== vmt-reid 결과: ubuntu-tpl -> db-01.db.internal =="
    assert_line /etc/hostname db-01
}

test_menu_reid_quit_and_eof() {
    write_conf
    clone
    input 'q\n'
    run bash "$REID" < "$VMT_TEST_SB/in"
    assert_rc 0
    assert_out "아무것도 바꾸지 않았다"
    input ''
    run bash "$REID" < "$VMT_TEST_SB/in"
    assert_rc 1
    assert_out "입력이 끝났다. 저장하지 않은 변경은 버린다"
    assert_line /etc/hostname ubuntu-tpl
}

# 이 VM에 맞지 않는 노드는 적용할 수 없고, 고친 뒤 적용한다
test_menu_reid_fix_plan_then_apply() {
    write_conf
    clone
    # web-01은 auto 후보가 둘이라 계획이 실패한다. NIC를 고쳐 enp0s9로 정한 뒤 적용한다
    input '1\na\ne\n6\nenp0s9\n\n\n\nn\nb\na\n'
    run bash "$REID" < "$VMT_TEST_SB/in"
    assert_rc 0
    assert_out "[nic mgmt]에 쓸 NIC 후보가 여럿이다"
    assert_out "  e) 고치기   b) 뒤로"
    assert_out "  ! 적용할 수 없는 계획이다"
    assert_out "  mgmt       enp0s9 ($MAC2) 고정 192.168.56.11/24"
    assert_line "$NP" "        macaddress: \"$MAC2\""
    # 복제본에서 고친 내용은 노드 목록에 쓰지 않고 적용 기록에만 남는다
    assert_no_grep "$CONF" 'enp0s9'
    assert_line /etc/vmt/node.conf "interface = enp0s9"
}

test_menu_reid_new_node_without_list() {
    clone
    # n(새 노드) → 이름 → NIC 추가(이름, interface, method, address, gateway, 고급 항목 n) → 끝 → 적용
    input 'n\nmenu-01\nn\n\nenp0s8\n\n\n300.1.1.1/24\n192.168.56.40/24\n\nn\nb\na\n'
    run bash "$REID" < "$VMT_TEST_SB/in"
    assert_rc 0
    assert_out "노드 목록  없음"
    assert_out "  ! 값이 있어야 한다"
    assert_out "  ! 주소는 IP/접두 형식으로 쓴다: 300.1.1.1/24"
    assert_line /etc/hostname menu-01
    assert_line /etc/hosts "192.168.56.40	menu-01.lab.internal	menu-01"
    assert_missing "$CONF"
}

test_menu_nodes_create_and_save() {
    # c(공통값: domain, dns, search, root_grow) → n(새 노드 web-01) → NIC 추가 → 디스크 추가 → b → s(저장) → q
    input 'c\nlab.internal\n192.168.56.1\n\nyes\nn\nweb-01\nn\n\n\n\n192.168.56.11/24\n\nn\nd\n\nsdb\n10G\nxfs\n/srv/data\nn\nb\ns\nq\n'
    run bash "$NODES" < "$VMT_TEST_SB/in"
    assert_rc 0
    assert_out "저장했다: $CONF"
    assert_line "$CONF" "[defaults]"
    assert_line "$CONF" "domain = lab.internal"
    assert_line "$CONF" "root_grow = yes"
    assert_line "$CONF" "[node web-01]"
    assert_line "$CONF" "[nic mgmt]"
    assert_line "$CONF" "address = 192.168.56.11/24"
    assert_line "$CONF" "[disk data]"
    assert_line "$CONF" "device = sdb"
    assert_line "$CONF" "size = 10G"
    assert_line "$CONF" "fs = xfs"
    assert_line "$CONF" "mount = /srv/data"
    run bash "$NODES" --check
    assert_rc 0
}

test_menu_nodes_unsaved_quit() {
    # 고정 주소 NIC를 dhcp로 바꾸면 address가 지워진다. 노드 지우기, 저장하지 않고 끝내기 확인
    write_conf
    input '1\n6\n\ndhcp\nn\nb\nx\n2\nq\nn\nq\ny\n'
    run bash "$NODES" < "$VMT_TEST_SB/in"
    assert_rc 0
    assert_out "  method = dhcp라 address와 gateway를 지웠다"
    assert_out "  지웠다: db-01"
    assert_out "(저장 안 함)"
    # 저장하지 않았으므로 파일은 그대로다
    assert_line "$CONF" "[node db-01]"
    assert_line "$CONF" "address = 192.168.56.11/24"
}

# 저장할 때 노드 전체를 검사한다. auto NIC가 둘이면 저장하지 않는다
test_menu_nodes_refuses_invalid_save() {
    write_conf
    input '1\nn\n\n\n\n192.168.57.10/24\n\nn\nb\ns\nq\ny\n'
    run bash "$NODES" < "$VMT_TEST_SB/in"
    assert_rc 0
    assert_out "[node web-01] [nic nic2] interface = auto는 노드마다 NIC 하나에만 쓴다"
    assert_out "저장하지 않았다. 오류를 고친 뒤 다시 저장한다"
    assert_no_grep "$CONF" 'nic2'
}

test_menu_nodes_save_keeps_backup() {
    write_conf
    input '1\n1\nweb-99\nb\ns\nq\n'
    run bash "$NODES" < "$VMT_TEST_SB/in"
    assert_rc 0
    assert_out "저장했다: $CONF (이전 파일: $CONF.bak)"
    assert_line "$CONF" "hostname = web-99"
    assert_line "$CONF.bak" "[node web-01]"
    assert_no_grep "$CONF.bak" 'web-99'
}

# ── vmt-clean 연동 ──────────────────────────────────────────────────────────
test_clean_validates_nodes_conf() {
    fx_file "$CONF" "[node bad]
[nic m]
address = 1.2.3"
    run bash "$CLEAN"
    assert_rc 1
    assert_out "$CONF:3: [node bad] [nic m] 주소는 IP/접두 형식으로 쓴다: 1.2.3"
    assert_missing /etc/vmt/template.env
    assert_exists /var/lib/systemd/random-seed
    write_conf
    run bash "$CLEAN"
    assert_rc 0
    assert_out "노드 목록      : $CONF (web-01 db-01)"
}
