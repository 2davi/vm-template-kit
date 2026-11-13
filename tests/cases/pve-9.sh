# shellcheck shell=bash
# Proxmox VE 9: vmbr0(NAT, 정적 10.0.2.15/24), pmxcfs(/etc/pve), 두 단계 vmt-reid.
# 복제본에는 어댑터 2(호스트 전용 enp0s8)를 붙이고, 1단계가 그 NIC로 관리망 브리지를 만든다.
CLEAN="$ROOT/dist/pve/9/vmt-clean"
REID="$ROOT/dist/pve/9/vmt-reid"
export PATH="$ROOT/tests/stubs-pve:$PATH"
MGMT_MAC=0a:00:27:ee:00:02
TPL_MID=55555555555555555555555555555555
USER_KEY='ssh-ed25519 AAAAC3UserKeyFromHostDavi davi@desktop'
TPL_ROOT_KEY_BODY='AAAATemplateRootKeyBody'
IFACES="auto lo
iface lo inet loopback

iface enp0s3 inet manual

auto vmbr0
iface vmbr0 inet static
	address 10.0.2.15/24
	gateway 10.0.2.2
	bridge-ports enp0s3
	bridge-stp off
	bridge-fd 0

source /etc/network/interfaces.d/*"

setup() {
    rm -rf /etc/network /etc/pve /etc/postfix /usr/local/lib/systemd/network /var/lib/rrdcached
    fx_os debian 13
    fx_hostname pve-tpl
    fx_file /etc/hosts "127.0.0.1 localhost.localdomain localhost
10.0.2.15 pve-tpl.lab.internal pve-tpl

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback"
    fx_file /etc/network/interfaces "$IFACES"
    fx_iface enp0s3 08:00:27:dd:00:01
    fx_port  enp0s3 vmbr0
    fx_iface vmbr0  08:00:27:dd:00:01 10.0.2.15/24
    fx_route vmbr0
    fx_machine_id "$TPL_MID"
    fx_ssh_keys
    fx_systemd_state
    fx_file /etc/mailname pve-tpl.lab.internal
    fx_file /etc/postfix/main.cf "myhostname=pve-tpl.lab.internal
mydestination = \$myhostname, localhost.\$mydomain, localhost"
    # pmxcfs 흉내: 일반 디렉터리
    mkdir -p /etc/pve/nodes/pve-tpl/qemu-server /etc/pve/nodes/pve-tpl/lxc /etc/pve/priv
    ln -sfn nodes/pve-tpl /etc/pve/local
    printf 'TEMPLATE-CA\n'      > /etc/pve/pve-root-ca.pem
    printf 'TEMPLATE-CA-KEY\n'  > /etc/pve/priv/pve-root-ca.key
    printf 'TEMPLATE-AUTH\n'    > /etc/pve/authkey.pub
    printf 'TEMPLATE-AUTHKEY\n' > /etc/pve/priv/authkey.key
    printf 'TEMPLATE-NODE-CERT\n' > /etc/pve/nodes/pve-tpl/pve-ssl.pem
    mkdir -p /root/.ssh
    printf 'TEMPLATE-ROOT-PRIVATE\n' > /root/.ssh/id_rsa
    printf 'ssh-rsa %s root@pve-tpl\n' "$TPL_ROOT_KEY_BODY" > /root/.ssh/id_rsa.pub
    printf 'ssh-rsa %s root@pve-tpl\n%s\n' "$TPL_ROOT_KEY_BODY" "$USER_KEY" > /etc/pve/priv/authorized_keys
    printf 'pve-tpl ssh-ed25519 AAAAOLD\n10.0.2.15 ssh-ed25519 AAAAOLD\nother-node ssh-ed25519 AAAAKEEP\n' \
        > /etc/pve/priv/known_hosts
    mkdir -p /var/lib/rrdcached/db/pve2-node /var/lib/rrdcached/db/pve2-storage/pve-tpl
    printf 'rrd\n' > /var/lib/rrdcached/db/pve2-node/pve-tpl
}

clone() {
    bash "$CLEAN" >/dev/null 2>&1
    fx_clone
    fx_iface enp0s8 "$MGMT_MAC"
}

# 재부팅을 흉내 낸다: 커널 호스트명이 바뀌고, 관리망 브리지가 새 IP로 올라오고, pmxcfs가 새 노드 디렉터리를 만들고,
# pveproxy 시작 전 updatecerts가 템플릿 CA로 새 노드 인증서를 먼저 발급한다
simulate_reboot() {  # 새 호스트명, [관리망 브리지 IP/접두]
    hostname "$1"
    fx_port enp0s8 vmbr1
    fx_iface vmbr1 "$MGMT_MAC" "${2:-}"
    mkdir -p "/etc/pve/nodes/$1/qemu-server" "/etc/pve/nodes/$1/lxc"
    ln -sfn "nodes/$1" /etc/pve/local
    printf 'CERT-SIGNED-BY-TEMPLATE-CA\n' > "/etc/pve/nodes/$1/pve-ssl.pem"
    printf 'KEY\n' > "/etc/pve/nodes/$1/pve-ssl.key"
}

test_clean_records_bridge_port_mac() {
    run bash "$CLEAN"
    assert_rc 0
    assert_eq "$(tpl_env VMT_TPL_IFACE)" vmbr0
    assert_eq "$(tpl_env VMT_TPL_CIDR)"  10.0.2.15/24
    assert_eq "$(tpl_env VMT_TPL_MAC)"   08:00:27:dd:00:01
    assert_eq "$(tpl_env VMT_TPL_FQDN)"  pve-tpl.lab.internal
    # 브리지 포트(enp0s3)는 관리망 NIC 후보가 아니므로 경고하지 않는다
    assert_not_out "NIC가 더 있다"
    assert_missing /var/lib/systemd/random-seed
}

test_clean_refuses_interface_pinning() {
    fx_file /usr/local/lib/systemd/network/50-pve-nic0.link "[Match]"
    run bash "$CLEAN"
    assert_rc 1
    assert_out "인터페이스 이름 고정(.link)"
}

test_clean_refuses_vm_present() {
    fx_file /etc/pve/nodes/pve-tpl/qemu-server/100.conf "memory: 512"
    run bash "$CLEAN"
    assert_rc 1
    assert_out "VM이 있다"
}

test_clean_refuses_pve_8() {
    VMT_TEST_PVE_VERSION=8.4.1 run bash "$CLEAN"
    assert_rc 1
    assert_out "Proxmox VE 9 전용"
}

test_reid_stage1_on_clone() {
    clone
    run bash "$REID" pve-01.lab.internal 192.168.56.21/24
    assert_rc 0
    assert_line /etc/hostname pve-01
    assert_eq "$(hostname)" pve-tpl "실행 중인 호스트명(1단계는 바꾸지 않는다)"
    assert_line /etc/hosts "192.168.56.21	pve-01.lab.internal	pve-01"
    assert_line /etc/hosts "127.0.0.1 localhost.localdomain localhost"
    assert_no_grep /etc/hosts 'pve-tpl|10\.0\.2\.15'
    # 원본은 그대로 두고 끝에 관리망 브리지를 더한다
    assert_eq "$(head -n "$(wc -l <<<"$IFACES")" /etc/network/interfaces)" "$IFACES" "원본 부분"
    assert_line /etc/network/interfaces 'iface enp0s8 inet manual'
    assert_line /etc/network/interfaces 'auto vmbr1'
    assert_line /etc/network/interfaces 'iface vmbr1 inet static'
    assert_line /etc/network/interfaces '	address 192.168.56.21/24'
    assert_line /etc/network/interfaces '	bridge-ports enp0s8'
    assert_line /etc/network/interfaces '#vmt-reid nic mgmt'
    assert_line /etc/network/interfaces '	address 10.0.2.15/24'
    assert_eq "$(grep -c 'gateway' /etc/network/interfaces)" 1 "gateway 줄 수"
    assert_line /etc/postfix/main.cf 'myhostname=pve-01.lab.internal'
    assert_line /etc/mailname pve-01.lab.internal
    assert_ne "$(cat /etc/machine-id)" "$TPL_MID" "machine-id"
    assert_grep /etc/ssh/ssh_host_ed25519_key '^NEW-'
    assert_grep /var/lib/vmt/pve-stage1 '^PVE_MGMT_BR=vmbr1$'
    assert_grep /var/lib/vmt/pve-stage1 '^PVE_OLD_IP=10\.0\.2\.15$'
    assert_missing /etc/vmt/reid.done
    assert_out "다음 순서: reboot, 그다음 vmt-reid --finish"
    # PVE에는 sudo가 기본으로 없다
    assert_not_out "sudo"
}

test_reid_stage1_refuses_template() {
    bash "$CLEAN" >/dev/null 2>&1
    fx_iface enp0s8 "$MGMT_MAC"
    run bash "$REID" pve-01.lab.internal 192.168.56.21/24
    assert_rc 1
    assert_out "템플릿 VM이다"
}

test_reid_stage1_twice_refused() {
    clone
    bash "$REID" pve-01.lab.internal 192.168.56.21/24 >/dev/null 2>&1
    run bash "$REID" pve-02.lab.internal 192.168.56.22/24
    assert_rc 1
    assert_out "1단계를 이미 했다"
}

# vmbr1이 이미 선언되어 있으면 다음 빈 번호를 쓰고, "inet manual" 선언은 겹쳐 쓰지 않는다
test_reid_stage1_picks_free_bridge() {
    fx_file /etc/network/interfaces "$IFACES

iface enp0s8 inet manual

auto vmbr1
iface vmbr1 inet manual
	bridge-ports none
	bridge-stp off
	bridge-fd 0"
    clone
    run bash "$REID" pve-01.lab.internal 192.168.56.21/24
    assert_rc 0
    assert_line /etc/network/interfaces 'iface vmbr2 inet static'
    assert_eq "$(grep -c '^iface enp0s8 inet manual$' /etc/network/interfaces)" 1 "enp0s8 선언 수"
    assert_grep /var/lib/vmt/pve-stage1 '^PVE_MGMT_BR=vmbr2$'
}

test_reid_stage1_refuses_mgmt_nic_in_use() {
    fx_file /etc/network/interfaces "$IFACES

auto vmbr1
iface vmbr1 inet manual
	bridge-ports enp0s8"
    clone
    run bash "$REID" pve-01.lab.internal 192.168.56.21/24
    assert_rc 1
    assert_out "/etc/network/interfaces가 enp0s8([nic mgmt])를 이미 쓴다"
    assert_missing /var/lib/vmt/pve-stage1
}

# 1단계가 남긴 관리망 브리지가 있는 VM은 템플릿으로 정리하지 않는다
test_clean_refuses_mgmt_bridge_left() {
    clone
    bash "$REID" pve-01.lab.internal 192.168.56.21/24 >/dev/null 2>&1
    run bash "$CLEAN"
    assert_rc 1
    assert_out "vmt-reid가 만든 NIC 설정이 남아 있다: /etc/network/interfaces"
}

test_reid_finish_requires_reboot() {
    clone
    bash "$REID" pve-01.lab.internal 192.168.56.21/24 >/dev/null 2>&1
    run bash "$REID" --finish
    assert_rc 1
    assert_out "재부팅했는지 확인한다"
}

test_reid_finish_requires_mgmt_address() {
    clone
    bash "$REID" pve-01.lab.internal 192.168.56.21/24 >/dev/null 2>&1
    simulate_reboot pve-01
    run bash "$REID" --finish
    assert_rc 1
    assert_out "vmbr1에 192.168.56.21/24가 없다"
    assert_exists /var/lib/vmt/pve-stage1
    assert_grep /etc/pve/pve-root-ca.pem 'TEMPLATE'
}

test_reid_finish_after_reboot() {
    clone
    bash "$REID" pve-01.lab.internal 192.168.56.21/24 >/dev/null 2>&1
    simulate_reboot pve-01 192.168.56.21/24
    run bash "$REID" --finish
    assert_rc 0
    assert_missing /etc/pve/nodes/pve-tpl
    assert_missing /var/lib/rrdcached/db/pve2-node/pve-tpl
    assert_missing /var/lib/rrdcached/db/pve2-storage/pve-tpl
    assert_no_grep /etc/pve/pve-root-ca.pem 'TEMPLATE'
    assert_no_grep /etc/pve/priv/authkey.key 'TEMPLATE'
    assert_grep /etc/pve/nodes/pve-01/pve-ssl.pem '^NEW-NODE-CERT pve-01$'
    assert_no_grep /root/.ssh/id_rsa 'TEMPLATE'
    assert_no_grep /etc/pve/priv/authorized_keys "$TPL_ROOT_KEY_BODY"
    assert_line /etc/pve/priv/authorized_keys "$USER_KEY"
    assert_no_grep /etc/pve/priv/known_hosts '^(pve-tpl|10\.0\.2\.15) '
    assert_line /etc/pve/priv/known_hosts 'other-node ssh-ed25519 AAAAKEEP'
    assert_called "pvecm updatecerts --force"
    assert_called "systemctl restart pvedaemon pveproxy"
    assert_grep /etc/vmt/reid.done 'pve-tpl -> pve-01\.lab\.internal node pve-01 vmt'
    assert_missing /var/lib/vmt/pve-stage1
    assert_out "https://192.168.56.21:8006"
}

test_reid_finish_without_stage1() {
    clone
    run bash "$REID" --finish
    assert_rc 1
    assert_out "1단계 기록"
}

# 노드 구성: NIC 둘. 고정 주소 NIC는 노드 IP 브리지(vmbr1), 주소 없는 NIC는 VM용 브리지(vmbr2)가 된다
test_reid_stage1_node_two_bridges() {
    fx_file /etc/vmt/nodes.conf "[node pve-02]
hostname = pve-02.lab.internal
dns = 192.168.56.1

[nic mgmt]
interface = enp0s8
address = 192.168.56.22/24

[nic vmnet]
interface = enp0s9
method = off
mtu = 9000"
    clone
    fx_iface enp0s9 0a:00:27:ee:00:03
    run bash "$REID" --node pve-02
    assert_rc 0
    assert_out "PVE에서는 dns, search를 적용하지 않는다"
    assert_line /etc/network/interfaces 'iface vmbr1 inet static'
    assert_line /etc/network/interfaces '	address 192.168.56.22/24'
    assert_line /etc/network/interfaces '#vmt-reid nic mgmt'
    assert_line /etc/network/interfaces 'iface vmbr2 inet manual'
    assert_line /etc/network/interfaces '	bridge-ports enp0s9'
    assert_line /etc/network/interfaces '	mtu 9000'
    assert_line /etc/network/interfaces '#vmt-reid nic vmnet'
    assert_line /etc/hosts "192.168.56.22	pve-02.lab.internal	pve-02"
    assert_line /var/lib/vmt/pve-stage1 'PVE_NODE=pve-02'
    assert_line /var/lib/vmt/pve-stage1 'PVE_MGMT_BR=vmbr1'
    assert_out "NIC 설정 파일 : /etc/network/interfaces의 vmbr1(포트 enp0s8), vmbr2(포트 enp0s9)"
    assert_out "설정 파일    /etc/network/interfaces의 vmbr1(포트 enp0s8), vmbr2(포트 enp0s9)"
    assert_out "다음 순서: reboot, 그다음 vmt-reid --finish"
}

# PVE 노드 규칙: dhcp, gateway, routes, 주소 여럿을 쓰지 않고 고정 주소 NIC가 있어야 한다
test_nodes_check_pve_rules() {
    fx_file /etc/vmt/nodes.conf "[node pve-x]
[nic a]
interface = enp0s8
method = dhcp
[nic b]
interface = enp0s9
address = 192.168.56.23/24, 192.168.56.24/24
gateway = 192.168.56.1
routes = 10.0.0.0/8 via 192.168.56.1
[node pve-y]
[nic c]
method = off"
    run bash "$ROOT/dist/pve/9/vmt-nodes" --check
    assert_rc 1
    assert_out "[node pve-x] [nic a] PVE에서는 method = dhcp를 쓰지 않는다"
    assert_out "[node pve-x] [nic b] PVE에서는 gateway를 쓰지 않는다"
    assert_out "[node pve-x] [nic b] PVE에서는 routes를 쓰지 않는다"
    assert_out "[node pve-x] [nic b] PVE에서는 브리지마다 주소를 하나만 쓴다"
    assert_out "[node pve-y] PVE 노드에는 method = static인 NIC가 하나 이상 있어야 한다"
}
