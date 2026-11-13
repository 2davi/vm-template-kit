# shellcheck shell=bash
# Rocky Linux 9: NetworkManager keyfile, SELinux, sshd-keygen@.service
CLEAN="$ROOT/dist/rocky/9/vmt-clean"
REID="$ROOT/dist/rocky/9/vmt-reid"
NM=/etc/NetworkManager/system-connections
NM_MGMT=$NM/vmt-mgmt.nmconnection
TPL_MID=22222222222222222222222222222222

# shellcheck source=tests/lib/fixture-rocky.sh
. "$ROOT/tests/lib/fixture-rocky.sh"

setup() { rocky_fixture 9.6; }

test_clean_records_template_and_strips_bindings() {
    run bash "$CLEAN"
    assert_rc 0
    assert_eq "$(tpl_env VMT_TPL_HOST)"  rocky-tpl
    # /etc/hostname에 FQDN을 적은 경우 그 값을 템플릿 FQDN으로 쓴다
    assert_eq "$(tpl_env VMT_TPL_FQDN)"  rocky-tpl.lab.internal
    assert_eq "$(tpl_env VMT_TPL_IFACE)" enp0s3
    assert_eq "$(tpl_env VMT_TPL_MAC)"   08:00:27:bb:00:01
    assert_no_grep "$NM/enp0s3.nmconnection" '^mac-address='
    assert_line    "$NM/enp0s3.nmconnection" 'interface-name=enp0s3'
    assert_eq "$(stat -c %a "$NM/enp0s3.nmconnection")" 600 "keyfile 권한"
    assert_missing /var/lib/NetworkManager/internal-0f0f-enp0s3.lease
    assert_missing /var/lib/NetworkManager/secret_key
    assert_missing /root/anaconda-ks.cfg
    assert_missing /var/lib/systemd/random-seed
    assert_called "dnf -q clean all"
    assert_called "restorecon -F $NM/enp0s3.nmconnection"
}

test_clean_keeps_policy_value_and_v2_secret_key() {
    sed -i '/^mac-address=/a cloned-mac-address=stable' "$NM/enp0s3.nmconnection"
    fx_file /var/lib/NetworkManager/secret_key "nm-v2:0123456789abcdef0123456789abcdef"
    run bash "$CLEAN"
    assert_rc 0
    assert_line "$NM/enp0s3.nmconnection" 'cloned-mac-address=stable'
    assert_exists /var/lib/NetworkManager/secret_key
}

# MAC으로만 NIC를 정한 프로필은 MAC 고정을 지우면 아무 NIC에나 붙을 수 있다
test_clean_warns_profile_without_interface_name() {
    sed -i '/^interface-name=/d' "$NM/enp0s3.nmconnection"
    run bash "$CLEAN"
    assert_rc 0
    assert_out "interface-name이 없다"
}

test_clean_refuses_ifcfg_profiles() {
    fx_file /etc/sysconfig/network-scripts/ifcfg-enp0s3 "DEVICE=enp0s3
HWADDR=08:00:27:bb:00:01
BOOTPROTO=dhcp"
    run bash "$CLEAN"
    assert_rc 1
    assert_out "nmcli connection migrate"
}

test_clean_refuses_rocky_10() {
    fx_os rocky 10.2
    run bash "$CLEAN"
    assert_rc 1
    assert_out "rocky 9 전용"
}

test_reid_on_clone() {
    clone
    run bash "$REID" rocky-01.lab.internal 192.168.56.41/24
    assert_rc 0
    assert_line /etc/hostname rocky-01
    # Rocky의 /etc/hosts에는 호스트명 줄이 없으므로 끝에 더한다
    assert_line /etc/hosts "192.168.56.41	rocky-01.lab.internal	rocky-01"
    assert_line /etc/hosts "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4"
    # 템플릿 NAT 프로필은 그대로 두고 관리망 프로필을 새로 만든다
    assert_line "$NM/enp0s3.nmconnection" 'method=auto'
    assert_line "$NM_MGMT" 'id=vmt-mgmt'
    assert_line "$NM_MGMT" 'mac-address=0A:00:27:EE:00:02'
    assert_line "$NM_MGMT" 'address1=192.168.56.41/24'
    assert_line "$NM_MGMT" 'never-default=true'
    assert_grep "$NM_MGMT" '^uuid=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    assert_no_grep "$NM_MGMT" '^interface-name='
    assert_eq "$(stat -c %a "$NM_MGMT")" 600 "keyfile 권한"
    assert_called "nmcli connection reload"
    assert_called "restorecon -F /etc/hostname /etc/hosts $NM_MGMT"
    assert_called "restorecon -F /etc/machine-id"
    assert_ne "$(cat /etc/machine-id)" "$TPL_MID" "machine-id"
    # sshd-keygen@.service가 있으면 지우기만 하고 재부팅 때 만들게 둔다
    assert_missing /etc/ssh/ssh_host_ed25519_key
    assert_not_called "ssh-keygen -A"
    assert_out "재부팅 때 sshd-keygen@.service가 새로 만든다"
    assert_exists /etc/vmt/reid.done
}

test_reid_without_sshd_keygen_unit() {
    rm -f /usr/lib/systemd/system/sshd-keygen@.service
    clone
    run bash "$REID" rocky-01.lab.internal 192.168.56.41/24
    assert_rc 0
    assert_called "ssh-keygen -A"
    assert_grep /etc/ssh/ssh_host_ed25519_key '^NEW-'
}

test_reid_skips_reload_when_nm_inactive() {
    clone
    fx_active_units
    run bash "$REID" rocky-01.lab.internal 192.168.56.41/24
    assert_rc 0
    assert_not_called "nmcli connection reload"
}

test_reid_refuses_profile_claiming_mgmt_nic() {
    fx_file "$NM/enp0s8.nmconnection" "[connection]
id=enp0s8
type=ethernet
interface-name=enp0s8

[ipv4]
method=auto"
    chmod 600 "$NM/enp0s8.nmconnection"
    clone
    run bash "$REID" rocky-01.lab.internal 192.168.56.41/24
    assert_rc 1
    assert_out "enp0s8([nic mgmt])를 맡는 프로필이 이미 있다: $NM/enp0s8.nmconnection"
    assert_missing "$NM_MGMT"
}

# 호스트 전용 네트워크의 DHCP 서버가 켜져 있으면 NetworkManager의 임시 기본 유선 연결이 주소를 받아 둔다
test_reid_warns_when_default_wired_connection_has_address() {
    clone
    printf '9: enp0s8    inet 192.168.56.101/24 brd 0.0.0.0 scope global enp0s8\n' >> "$VMT_TEST_SB/ip-addr"
    run bash "$REID" rocky-01.lab.internal 192.168.56.41/24
    assert_rc 0
    assert_out "이미 주소(192.168.56.101/24)가 있다"
    assert_line "$NM_MGMT" 'address1=192.168.56.41/24'
}

# 노드 구성: NIC 셋(고정 주소 둘·게이트웨이·경로·DNS, DHCP, 주소 없음)과 추가 디스크
test_reid_node_multi_nic_and_disk() {
    fx_file /etc/vmt/nodes.conf "[node rk-01]
dns = 192.168.56.1, 1.1.1.1
search = lab.internal

[nic mgmt]
interface = enp0s8
address = 192.168.56.51/24, 192.168.56.52/24
gateway = 192.168.56.1
routes = 10.20.0.0/16 via 192.168.56.254
mtu = 9000

[nic data]
interface = enp0s9
method = dhcp

[nic link]
interface = enp0s10
method = off

[disk data]
device = sdb
fs = xfs
mount = /srv/data"
    clone
    fx_iface enp0s9 0a:00:27:ee:00:03
    fx_iface enp0s10 0a:00:27:ee:00:04
    fx_disk sdb 10240
    run bash "$REID" --node rk-01
    assert_rc 0
    local m=$NM/vmt-mgmt.nmconnection d=$NM/vmt-data.nmconnection l=$NM/vmt-link.nmconnection
    assert_line "$m" 'id=vmt-mgmt'
    assert_line "$m" 'mac-address=0A:00:27:EE:00:02'
    assert_line "$m" 'mtu=9000'
    assert_line "$m" 'address1=192.168.56.51/24'
    assert_line "$m" 'address2=192.168.56.52/24'
    assert_line "$m" 'gateway=192.168.56.1'
    assert_line "$m" 'route-metric=50'
    assert_no_grep "$m" '^never-default'
    assert_line "$m" 'route1=10.20.0.0/16,192.168.56.254'
    assert_line "$m" 'dns=192.168.56.1;1.1.1.1;'
    assert_line "$m" 'dns-search=lab.internal;'
    assert_line "$d" 'method=auto'
    assert_line "$d" 'route-metric=2000'
    assert_no_grep "$d" '^dns='
    assert_eq "$(grep -c '^method=disabled' "$l")" 2 "link의 ipv4, ipv6 method=disabled"
    assert_eq "$(stat -c %a "$m")" 600 "프로필 권한"
    assert_called "restorecon -F /etc/hostname /etc/hosts $d $l $m"
    assert_called "restorecon -F -R /srv/data"
    assert_line /etc/hosts "192.168.56.51	rk-01.lab.internal	rk-01"
    assert_out "NIC 설정 파일 : $m, $d, $l"
    assert_out "설정 파일    $m, $d, $l"
}

# 다시 실행할 때 이전 실행의 vmt 프로필을 지우고 다시 만든다
test_reid_rerun_replaces_profiles() {
    fx_file /etc/vmt/nodes.conf "[node rk-02]
[nic old]
interface = enp0s8
address = 192.168.56.53/24"
    clone
    run bash "$REID" --node rk-02
    assert_rc 0
    rm -f /etc/vmt/reid.done
    sed -i 's/\[nic old\]/[nic new]/' /etc/vmt/nodes.conf
    run bash "$REID" --node rk-02
    assert_rc 0
    assert_missing "$NM/vmt-old.nmconnection"
    assert_exists "$NM/vmt-new.nmconnection"
}

test_clean_refuses_leftover_vmt_profiles() {
    fx_file "$NM/vmt-data.nmconnection" "[connection]"
    run bash "$CLEAN"
    assert_rc 1
    assert_out "vmt-reid가 만든 NIC 설정이 남아 있다: $NM/vmt-data.nmconnection"
}
