# shellcheck shell=bash
# Debian 13: ifupdown, dhcpcd, 설치 관리자 cdebconf
# VirtualBox 템플릿: 어댑터 1 NAT(enp0s3, DHCP). 복제본에는 어댑터 2(호스트 전용 enp0s8)를 붙인다.
CLEAN="$ROOT/dist/debian/13/vmt-clean"
REID="$ROOT/dist/debian/13/vmt-reid"
IF_MGMT=/etc/network/interfaces.d/vmt
MGMT_MAC=0a:00:27:ee:00:02
TPL_MID=44444444444444444444444444444444
IFACES="source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug enp0s3
iface enp0s3 inet dhcp"

setup() {
    rm -rf /etc/network /var/lib/dhcpcd /var/log/installer
    fx_os debian 13
    fx_hostname deb-tpl
    fx_file /etc/hosts "127.0.0.1	localhost
127.0.1.1	deb-tpl.lab.internal	deb-tpl

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes"
    fx_file /etc/network/interfaces "$IFACES"
    mkdir -p /etc/network/interfaces.d
    fx_iface enp0s3 08:00:27:cc:00:01 10.0.2.15/24
    fx_route enp0s3
    fx_machine_id "$TPL_MID"
    fx_ssh_keys
    fx_systemd_state
    fx_file /etc/mailname deb-tpl.lab.internal
    fx_file /var/lib/dhcpcd/duid "00:04:template-duid"
    fx_file /var/lib/dhcpcd/secret "template-secret"
    fx_file /var/lib/dhcpcd/enp0s3.lease "lease"
    fx_file /var/log/installer/cdebconf/questions.dat "Name: passwd/user-password"
}

clone() {
    bash "$CLEAN" >/dev/null 2>&1
    fx_clone
    fx_iface enp0s8 "$MGMT_MAC"
}

test_clean_records_template() {
    run bash "$CLEAN"
    assert_rc 0
    assert_eq "$(tpl_env VMT_TPL_IFACE)" enp0s3
    assert_eq "$(tpl_env VMT_TPL_FQDN)"  deb-tpl.lab.internal
    assert_missing /var/log/installer/cdebconf
    assert_missing /var/lib/dhcpcd/enp0s3.lease
    assert_exists  /var/lib/dhcpcd/duid
    assert_called "apt-get clean"
}

test_clean_refuses_pve_node() {
    PATH="$ROOT/tests/stubs-pve:$PATH" run bash "$CLEAN"
    assert_rc 1
    assert_out "Proxmox VE 노드다"
}

test_clean_refuses_without_interfaces_d_source() {
    fx_file /etc/network/interfaces "auto lo
iface lo inet loopback

allow-hotplug enp0s3
iface enp0s3 inet dhcp"
    run bash "$CLEAN"
    assert_rc 1
    assert_out "interfaces.d를 읽지 않는다"
    assert_missing /etc/vmt/template.env
}

test_clean_refuses_on_clone() {
    clone
    bash "$REID" deb-01.lab.internal 192.168.56.31/24 >/dev/null 2>&1
    run bash "$CLEAN"
    assert_rc 1
    assert_out "vmt-reid를 실행한 복제본이다"
}

test_reid_on_clone() {
    clone
    run bash "$REID" deb-01.lab.internal 192.168.56.31/24
    assert_rc 0
    assert_line /etc/hostname deb-01
    assert_line /etc/hosts "192.168.56.31	deb-01.lab.internal	deb-01"
    assert_line /etc/hosts "::1     localhost ip6-localhost ip6-loopback"
    assert_no_grep /etc/hosts 'deb-tpl|127\.0\.1\.1'
    # 템플릿 설정은 그대로 두고 interfaces.d에 관리망 스탠자를 새로 만든다
    assert_eq "$(cat /etc/network/interfaces)" "$IFACES" "/etc/network/interfaces"
    assert_line "$IF_MGMT" 'allow-hotplug enp0s8'
    assert_line "$IF_MGMT" 'iface enp0s8 inet static'
    assert_line "$IF_MGMT" '    address 192.168.56.31/24'
    assert_line "$IF_MGMT" "# [nic mgmt] 만들 때 MAC: $MGMT_MAC"
    assert_line /etc/mailname deb-01.lab.internal
    assert_missing /var/lib/dhcpcd/duid
    assert_missing /var/lib/dhcpcd/secret
    assert_called "ssh-keygen -A"
    assert_grep /etc/ssh/ssh_host_ed25519_key '^NEW-'
    assert_ne "$(cat /etc/machine-id)" "$TPL_MID" "machine-id"
    assert_exists /etc/vmt/reid.done
}

test_reid_refuses_declared_mgmt_iface() {
    fx_file /etc/network/interfaces "$IFACES

allow-hotplug enp0s8
iface enp0s8 inet dhcp"
    clone
    run bash "$REID" deb-01.lab.internal 192.168.56.31/24
    assert_rc 1
    assert_out "enp0s8([nic mgmt])를 설정하는 스탠자가 이미 있다: /etc/network/interfaces"
    assert_missing "$IF_MGMT"
}

# D-Bus 쪽 machine-id가 링크가 아닌 일반 파일이면 옛 값이 되살아나지 않게 지우고 링크로 둔다
test_reid_replaces_dbus_machine_id_file() {
    clone
    rm -f /var/lib/dbus/machine-id
    printf '%s\n' "$TPL_MID" > /var/lib/dbus/machine-id
    run bash "$REID" deb-01.lab.internal 192.168.56.31/24
    assert_rc 0
    assert_ne "$(cat /etc/machine-id)" "$TPL_MID" "machine-id"
    assert_eq "$(readlink /var/lib/dbus/machine-id)" /etc/machine-id "dbus 링크"
}

test_reid_refuses_machine_id_mountpoint() {
    clone
    printf 'runtime\n' > /run/machine-id
    mount --bind /run/machine-id /etc/machine-id
    run bash "$REID" deb-01.lab.internal 192.168.56.31/24
    umount /etc/machine-id
    assert_rc 1
    assert_out "마운트 지점이다"
    # 아무것도 바꾸기 전에 거부한다
    assert_line /etc/hostname deb-tpl
    assert_missing /var/lib/vmt/reid-backup
    assert_missing "$IF_MGMT"
}

# Hyper-V: NAT는 Default Switch(eth0, DHCP), 관리망은 내부 스위치 LabNet(eth1)
test_hyperv_default_switch_and_labnet() {
    rm -rf "${VMT_TEST_SB:?}"/net/*
    : > "$VMT_TEST_SB/ip-addr"
    : > "$VMT_TEST_SB/ip-route"
    fx_file /etc/network/interfaces "source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp"
    fx_iface eth0 00:15:5d:00:00:30 172.27.240.30/20
    fx_route eth0 172.27.240.1
    bash "$CLEAN" >/dev/null 2>&1
    fx_clone
    fx_iface eth1 00:15:5d:00:00:31
    run bash "$REID" deb-01.lab.internal 192.168.57.31/24
    assert_rc 0
    assert_line "$IF_MGMT" 'iface eth1 inet static'
    assert_line "$IF_MGMT" '    address 192.168.57.31/24'
}

# 노드 구성: 주소 둘(스탠자 둘), 게이트웨이와 metric, 경로, DNS, DHCP, 주소 없음
test_reid_node_multi_nic() {
    fx_file /etc/vmt/nodes.conf "[node dn-01]
dns = 192.168.56.1
search = lab.internal

[nic mgmt]
interface = enp0s8
address = 192.168.56.31/24, 192.168.56.32/24
gateway = 192.168.56.1
routes = 10.20.0.0/16 via 192.168.56.254
mtu = 9000

[nic data]
interface = enp0s9
method = dhcp
mtu = 1400

[nic link]
interface = enp0s10
method = off"
    clone
    fx_iface enp0s9 0a:00:27:ee:00:03
    fx_iface enp0s10 0a:00:27:ee:00:04
    run bash "$REID" --node dn-01
    assert_rc 0
    assert_eq "$(grep -c '^iface enp0s8 inet static' "$IF_MGMT")" 2 "enp0s8 스탠자 수"
    assert_line "$IF_MGMT" '    address 192.168.56.31/24'
    assert_line "$IF_MGMT" '    address 192.168.56.32/24'
    assert_line "$IF_MGMT" '    gateway 192.168.56.1'
    assert_line "$IF_MGMT" '    metric 50'
    assert_line "$IF_MGMT" '    mtu 9000'
    assert_line "$IF_MGMT" '    up ip route add 10.20.0.0/16 via 192.168.56.254 dev enp0s8'
    assert_line "$IF_MGMT" '    down ip route del 10.20.0.0/16 via 192.168.56.254 dev enp0s8 || true'
    assert_line "$IF_MGMT" '    dns-nameservers 192.168.56.1'
    assert_line "$IF_MGMT" '    dns-search lab.internal'
    assert_eq "$(grep -c 'dns-nameservers' "$IF_MGMT")" 1 "dns-nameservers 줄 수"
    assert_line "$IF_MGMT" 'iface enp0s9 inet dhcp'
    assert_line "$IF_MGMT" '    metric 2000'
    assert_line "$IF_MGMT" '    pre-up ip link set dev enp0s9 mtu 1400'
    assert_line "$IF_MGMT" 'allow-hotplug enp0s10'
    assert_line "$IF_MGMT" 'iface enp0s10 inet manual'
    # resolvconf가 없으면 DNS 줄이 반영되지 않는다는 경고
    if ! command -v resolvconf >/dev/null; then
        assert_out "resolvconf가 없어 dns-nameservers, dns-search가 반영되지 않는다"
    fi
}
