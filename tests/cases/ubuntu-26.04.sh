# shellcheck shell=bash
# Ubuntu Server 26.04: VirtualBox 템플릿(어댑터 1 NAT enp0s3), 복제본에 어댑터 2(호스트 전용 enp0s8)를 붙인다.
# 공통 처리(/etc/hosts, 관리망 NIC 선택, 입력 검사, 다시 실행)는 이 케이스에서 주로 검사한다.
CLEAN="$ROOT/dist/ubuntu/26.04/vmt-clean"
REID="$ROOT/dist/ubuntu/26.04/vmt-reid"
NP_NAT=/etc/netplan/50-cloud-init.yaml
NP_MGMT=/etc/netplan/60-vmt.yaml
MGMT_MAC=0a:00:27:ee:00:02
TPL_MID=11111111111111111111111111111111

setup() {
    rm -rf /etc/netplan /etc/cloud
    fx_os ubuntu 26.04
    fx_hostname ubuntu-tpl
    fx_file /etc/hosts "127.0.0.1 localhost
127.0.1.1 ubuntu-tpl.lab.internal ubuntu-tpl

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet"
    fx_file "$NP_NAT" "network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true"
    chmod 600 "$NP_NAT"
    fx_iface enp0s3 08:00:27:aa:00:01 10.0.2.15/24
    fx_route enp0s3
    fx_machine_id "$TPL_MID"
    fx_ssh_keys
    fx_systemd_state
    fx_file /var/log/installer/autoinstall-user-data "identity: {password: '\$6\$hash'}"
    fx_file /etc/cloud/cloud-init.disabled "disabled by installer"
}

# 템플릿을 정리하고, 복제본처럼 MAC을 바꾸고, 관리망 NIC를 붙인다
clone() {
    bash "$CLEAN" >/dev/null 2>&1
    fx_clone
    fx_iface enp0s8 "$MGMT_MAC"
}

test_clean_records_template() {
    run bash "$CLEAN"
    assert_rc 0
    assert_eq "$(tpl_env VMT_TPL_SCHEMA)" 2
    assert_eq "$(tpl_env VMT_TPL_HOST)"   ubuntu-tpl
    assert_eq "$(tpl_env VMT_TPL_FQDN)"   ubuntu-tpl.lab.internal
    assert_eq "$(tpl_env VMT_TPL_IFACE)"  enp0s3
    assert_eq "$(tpl_env VMT_TPL_CIDR)"   10.0.2.15/24
    assert_eq "$(tpl_env VMT_TPL_MAC)"    08:00:27:aa:00:01
    assert_missing /var/lib/systemd/random-seed
    assert_missing /var/lib/systemd/credential.secret
    assert_missing /var/log/installer/autoinstall-user-data
    assert_called "systemctl stop systemd-random-seed.service"
    assert_called "apt-get clean"
    # 템플릿의 식별 정보와 네트워크 설정은 그대로 둔다
    assert_eq "$(cat /etc/machine-id)" "$TPL_MID"
    assert_exists /etc/ssh/ssh_host_ed25519_key
    assert_line "$NP_NAT" '      dhcp4: true'
    assert_out "NAT 인터페이스 : enp0s3 (10.0.2.15/24, MAC 08:00:27:aa:00:01)"
}

test_clean_without_fqdn() {
    fx_file /etc/hosts "127.0.0.1 localhost
127.0.1.1 ubuntu-tpl"
    run bash "$CLEAN"
    assert_rc 0
    assert_eq "$(tpl_env VMT_TPL_FQDN)" ""
}

test_clean_warns_cloud_init_enabled() {
    rm -f /etc/cloud/cloud-init.disabled
    run bash "$CLEAN"
    assert_rc 0
    assert_out "cloud-init이 켜져 있다"
}

test_clean_warns_netplan_mode_and_mac_match() {
    fx_file "$NP_NAT" "network:
  version: 2
  ethernets:
    nat:
      match:
        macaddress: 08:00:27:aa:00:01
      dhcp4: true"
    chmod 644 "$NP_NAT"
    run bash "$CLEAN"
    assert_rc 0
    assert_out "권한이 644다"
    assert_out "MAC으로 NIC를 찾는다"
}

test_clean_refuses_without_default_route() {
    : > "$VMT_TEST_SB/ip-route"
    run bash "$CLEAN"
    assert_rc 1
    assert_out "기본 경로를 가진 인터페이스가 하나여야 한다. 찾은 인터페이스: 없음"
    assert_missing /etc/vmt/template.env
}

test_clean_refuses_two_default_routes() {
    fx_iface enp0s8 08:00:27:aa:00:02 10.0.3.15/24
    fx_route enp0s8 10.0.3.2
    run bash "$CLEAN"
    assert_rc 1
    assert_out "찾은 인터페이스: enp0s3 enp0s8"
}

test_clean_warns_extra_nic() {
    fx_iface enp0s8 08:00:27:aa:00:02 192.168.56.10/24
    run bash "$CLEAN"
    assert_rc 0
    assert_out "NAT 말고 NIC가 더 있다: enp0s8"
}

test_clean_refuses_leftover_mgmt_conf() {
    fx_file "$NP_MGMT" "network: {version: 2}"
    run bash "$CLEAN"
    assert_rc 1
    assert_out "vmt-reid가 만든 NIC 설정이 남아 있다: $NP_MGMT"
}

test_clean_refuses_wrong_version() {
    fx_os ubuntu 24.04
    run bash "$CLEAN"
    assert_rc 1
    assert_out "ubuntu 26.04 전용"
}

test_reid_refuses_template_vm() {
    bash "$CLEAN" >/dev/null 2>&1
    fx_iface enp0s8 "$MGMT_MAC"
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "템플릿 VM이다"
    assert_line /etc/hostname ubuntu-tpl
}

test_reid_refuses_without_template_env() {
    fx_clone
    fx_iface enp0s8 "$MGMT_MAC"
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "템플릿 기록"
}

test_reid_refuses_other_schema() {
    clone
    sed -i '/^VMT_TPL_SCHEMA=/d' /etc/vmt/template.env
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "템플릿 기록 형식이 이 버전과 다르다"
}

test_reid_on_clone() {
    clone
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 0
    assert_line /etc/hostname ubuntu-01
    assert_eq "$(hostname)" ubuntu-01 "실행 중인 호스트명"
    assert_line /etc/hosts "192.168.56.11	ubuntu-01.lab.internal	ubuntu-01"
    assert_line /etc/hosts "127.0.0.1 localhost"
    assert_line /etc/hosts "::1     ip6-localhost ip6-loopback"
    assert_no_grep /etc/hosts 'ubuntu-tpl|127\.0\.1\.1'
    # 템플릿의 NAT 설정은 그대로 두고 관리망 설정을 새로 만든다
    assert_line "$NP_NAT" '      dhcp4: true'
    assert_line "$NP_MGMT" "        macaddress: \"$MGMT_MAC\""
    assert_line "$NP_MGMT" '        - 192.168.56.11/24'
    assert_line "$NP_MGMT" '      dhcp4: false'
    assert_line "$NP_MGMT" '      optional: true'
    assert_eq "$(stat -c %a "$NP_MGMT")" 600 "netplan 파일 권한"
    assert_called "netplan generate"
    assert_ne "$(cat /etc/machine-id)" "$TPL_MID" "machine-id"
    assert_eq "$(readlink /var/lib/dbus/machine-id)" /etc/machine-id "dbus 링크"
    assert_grep /etc/ssh/ssh_host_ed25519_key '^NEW-'
    assert_grep /etc/vmt/reid.done 'ubuntu-tpl -> ubuntu-01\.lab\.internal node ubuntu-01 vmt'
    assert_out "NIC mgmt : enp0s8 (MAC $MGMT_MAC) static 192.168.56.11/24"
    assert_out "다음 순서: sudo reboot"
}

test_reid_short_name_takes_template_domain() {
    clone
    run bash "$REID" ubuntu-02 192.168.56.12/24
    assert_rc 0
    assert_line /etc/hosts "192.168.56.12	ubuntu-02.lab.internal	ubuntu-02"
}

test_reid_short_name_without_template_domain() {
    fx_file /etc/hosts "127.0.0.1 localhost
127.0.1.1 ubuntu-tpl"
    clone
    run bash "$REID" ubuntu-02 192.168.56.12/24
    assert_rc 0
    assert_line /etc/hosts "192.168.56.12	ubuntu-02"
    assert_no_grep /etc/hosts 'lab\.internal'
}

test_reid_refuses_without_mgmt_nic() {
    bash "$CLEAN" >/dev/null 2>&1
    fx_clone
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "관리망 NIC 후보가 없다. 호스트에서 복제본에 어댑터"
    assert_missing "$NP_MGMT"
}

test_reid_refuses_two_candidates_then_iface() {
    clone
    fx_iface enp0s9 0a:00:27:ee:00:03
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "관리망 NIC 후보가 여럿이다: enp0s8(0a:00:27:ee:00:02), enp0s9(0a:00:27:ee:00:03). --iface로 지정한다"
    run bash "$REID" --iface enp0s9 ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 0
    assert_line "$NP_MGMT" '        macaddress: "0a:00:27:ee:00:03"'
}

test_reid_iface_option_checks() {
    clone
    fx_iface vmbr9 0a:00:27:ee:00:09
    run bash "$REID" --iface enp0s3 ubuntu-01 192.168.56.11/24;  assert_rc 1; assert_out "템플릿의 NAT 인터페이스다"
    run bash "$REID" --iface vmbr9 ubuntu-01 192.168.56.11/24;   assert_rc 1; assert_out "물리 NIC가 아니다"
    run bash "$REID" --iface enp0s7 ubuntu-01 192.168.56.11/24;  assert_rc 1; assert_out "인터페이스가 없다"
    run bash "$REID" --iface;                                    assert_rc 2
    assert_missing "$NP_MGMT"
}

# 기본 경로를 가진 NIC는 관리망 후보에서 뺀다. 그 NIC밖에 없으면 그 사실을 알려 준다
test_reid_skips_nic_with_default_route() {
    clone
    fx_route enp0s8 192.168.56.1
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "기본 경로를 가진 NIC(enp0s8)는 NAT 쪽으로 보고 뺐다"
}

# Hyper-V에서 NIC 순서가 바뀌면 템플릿의 NAT 이름(eth0)이 내부 스위치 NIC가 되어 DHCP를 받지 못한다
test_reid_refuses_when_nat_has_no_default_route() {
    clone
    : > "$VMT_TEST_SB/ip-route"
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "NAT 인터페이스 enp0s3에 기본 경로가 없다"
    assert_line /etc/hostname ubuntu-tpl
}

test_reid_refuses_nat_overlap() {
    clone
    run bash "$REID" ubuntu-01.lab.internal 10.0.2.50/24
    assert_rc 1
    assert_out "NAT 쪽 대역(enp0s3 10.0.2.15/24)과 겹친다"
}

test_reid_warns_when_mgmt_nic_has_address() {
    clone
    printf '9: enp0s8    inet 192.168.56.101/24 brd 0.0.0.0 scope global enp0s8\n' >> "$VMT_TEST_SB/ip-addr"
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 0
    assert_out "enp0s8([nic mgmt])에 이미 주소(192.168.56.101/24)가 있다"
}

# 템플릿의 netplan 설정이 관리망 NIC도 맡으면 networkd가 관리망 설정을 무시할 수 있다
test_reid_refuses_netplan_claiming_mgmt_nic() {
    fx_file "$NP_NAT" "network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: true"
    chmod 600 "$NP_NAT"
    clone
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "다른 netplan 설정이 enp0s8([nic mgmt])를 맡는다: $NP_NAT"
    assert_missing "$NP_MGMT"
}

test_reid_refuses_netplan_glob_match() {
    fx_file "$NP_NAT" "network:
  version: 2
  ethernets:
    all-en:
      match:
        name: \"en*\"
      dhcp4: true"
    chmod 600 "$NP_NAT"
    clone
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "다른 netplan 설정이 enp0s8([nic mgmt])를 맡는다"
}

test_reid_input_validation() {
    clone
    run bash "$REID" Bad_Name 192.168.56.11/24;                  assert_rc 1; assert_out "호스트명 형식"
    run bash "$REID" ubuntu-01.Lab_Internal 192.168.56.11/24;    assert_rc 1; assert_out "FQDN 형식"
    run bash "$REID" ubuntu-01 192.168.56.300/24;                assert_rc 1; assert_out "IP/접두 형식"
    run bash "$REID" ubuntu-01 192.168.56.11;                    assert_rc 1; assert_out "IP/접두 형식"
    run bash "$REID" ubuntu-01 192.168.56.0/24;                  assert_rc 1; assert_out "호스트 주소로 쓸 수 없는 IP"
    run bash "$REID" ubuntu-01 192.168.56.255/24;                assert_rc 1; assert_out "호스트 주소로 쓸 수 없는 IP"
    run bash "$REID" ubuntu-01 127.0.0.5/8;                      assert_rc 1; assert_out "호스트 주소로 쓸 수 없는 IP"
    run bash "$REID" ubuntu-01;                                  assert_rc 2
    run bash "$REID" a b c;                                      assert_rc 2
    run bash "$REID" --bogus ubuntu-01 192.168.56.11/24;         assert_rc 2
    run bash "$REID" ubuntu-tpl.lab.internal 192.168.56.11/24;   assert_rc 1; assert_out "템플릿 호스트명과 같다"
    assert_line /etc/hostname ubuntu-tpl
    assert_missing /etc/vmt/reid.done
    assert_missing /var/lib/vmt/reid-backup
}

test_reid_twice_refused() {
    clone
    bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24 >/dev/null 2>&1
    run bash "$REID" ubuntu-02.lab.internal 192.168.56.12/24
    assert_rc 1
    assert_out "이미 실행했다"
    assert_line /etc/hostname ubuntu-01
}

# 중간에 실패해도 같은 명령(값을 고친 명령 포함)을 다시 실행하면 처음 원본에서 다시 만든다
test_reid_rerun_after_failure() {
    clone
    touch "$VMT_TEST_SB/netplan-fail"
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 1
    assert_out "netplan generate 실패"
    assert_missing /etc/vmt/reid.done
    rm -f "$VMT_TEST_SB/netplan-fail"
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.21/24
    assert_rc 0
    assert_line /etc/hosts "192.168.56.21	ubuntu-01.lab.internal	ubuntu-01"
    assert_no_grep /etc/hosts '192\.168\.56\.11'
    assert_line "$NP_MGMT" '        - 192.168.56.21/24'
    assert_grep /var/lib/vmt/reid-backup/etc/hosts 'ubuntu-tpl'
}

# 템플릿에 실습 노드 목록을 미리 적어 두면 그 줄을 쓰고 새 줄을 넣지 않는다
test_reid_with_prepopulated_hosts() {
    fx_file /etc/hosts "127.0.0.1 localhost
127.0.1.1 ubuntu-tpl.lab.internal ubuntu-tpl
192.168.56.11 ubuntu-01.lab.internal ubuntu-01
192.168.56.12 ubuntu-02.lab.internal ubuntu-02"
    clone
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 0
    assert_eq "$(grep -c 'ubuntu-01' /etc/hosts)" 1 "ubuntu-01 줄 수"
    assert_line /etc/hosts "192.168.56.11 ubuntu-01.lab.internal ubuntu-01"
    assert_line /etc/hosts "192.168.56.12 ubuntu-02.lab.internal ubuntu-02"
    assert_no_grep /etc/hosts 'ubuntu-tpl'
}

test_reid_refuses_hosts_conflict() {
    fx_file /etc/hosts "127.0.0.1 localhost
127.0.1.1 ubuntu-tpl
192.168.56.12 ubuntu-01
192.168.56.11 other-node"
    clone
    run bash "$REID" ubuntu-01 192.168.56.11/24
    assert_rc 1
    assert_out "192.168.56.12 ubuntu-01"
    assert_out "192.168.56.11 other-node"
    assert_line /etc/hostname ubuntu-tpl
}

# 템플릿 이름이 localhost 줄에 있으면 그 이름만 빼고, 이름이 남지 않는 줄은 지운다
test_reid_hosts_template_name_on_loopback() {
    fx_file /etc/hosts "127.0.0.1 localhost ubuntu-tpl
::1 ubuntu-tpl"
    clone
    run bash "$REID" ubuntu-01.lab.internal 192.168.56.11/24
    assert_rc 0
    assert_line /etc/hosts "127.0.0.1	localhost"
    assert_no_grep /etc/hosts '^::1'
    assert_line /etc/hosts "192.168.56.11	ubuntu-01.lab.internal	ubuntu-01"
}

# Hyper-V: NAT는 Default Switch(eth0, DHCP), 관리망은 내부 스위치 LabNet(eth1)
test_hyperv_default_switch_and_labnet() {
    rm -rf "${VMT_TEST_SB:?}"/net/*
    : > "$VMT_TEST_SB/ip-addr"
    : > "$VMT_TEST_SB/ip-route"
    fx_file "$NP_NAT" "network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true"
    chmod 600 "$NP_NAT"
    fx_iface eth0 00:15:5d:01:02:03 172.27.240.15/20
    fx_route eth0 172.27.240.1
    bash "$CLEAN" >/dev/null 2>&1
    assert_eq "$(tpl_env VMT_TPL_IFACE)" eth0
    fx_clone
    fx_iface eth1 00:15:5d:01:02:99
    run bash "$REID" ubuntu-01.lab.internal 192.168.57.11/24
    assert_rc 0
    assert_line "$NP_MGMT" '        macaddress: "00:15:5d:01:02:99"'
    assert_line "$NP_MGMT" '        - 192.168.57.11/24'
    assert_out "NIC mgmt : eth1"
}
