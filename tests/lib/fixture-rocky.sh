# shellcheck shell=bash
# Rocky Linux 9, 10 케이스가 함께 쓰는 고정 데이터.
# 케이스 파일이 NM(keyfile 디렉터리)과 TPL_MID(템플릿 machine-id)를 먼저 정의한다.
# VirtualBox 템플릿: 어댑터 1 NAT(enp0s3, DHCP). Anaconda가 만든 프로필에는 MAC 고정 줄이 있다.
# 복제본에는 어댑터 2(호스트 전용 enp0s8)를 붙인다.
MGMT_MAC=0a:00:27:ee:00:02

rocky_fixture() {  # $1=VERSION_ID
    rm -rf "$NM" /etc/sysconfig/network-scripts /var/lib/NetworkManager
    fx_os rocky "$1"
    fx_hostname rocky-tpl.lab.internal
    fx_file /etc/hosts "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6"
    fx_file "$NM/enp0s3.nmconnection" "[connection]
id=enp0s3
uuid=0f0f0f0f-0000-4000-8000-000000000003
type=ethernet
interface-name=enp0s3

[ethernet]
mac-address=08:00:27:BB:00:01

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto"
    chmod 600 "$NM"/*.nmconnection
    fx_iface enp0s3 08:00:27:bb:00:01 10.0.2.15/24
    fx_route enp0s3
    fx_machine_id "$TPL_MID"
    fx_ssh_keys
    fx_systemd_state
    fx_file /var/lib/NetworkManager/internal-0f0f-enp0s3.lease "ADDRESS=10.0.2.15"
    fx_file /var/lib/NetworkManager/secret_key "v1-legacy-key-without-prefix-0123456789"
    fx_file /root/anaconda-ks.cfg "rootpw --iscrypted \$6\$hash"
    fx_file /usr/lib/systemd/system/sshd-keygen@.service "[Unit]"
    fx_active_units NetworkManager
}

clone() {
    bash "$CLEAN" >/dev/null 2>&1
    fx_clone
    fx_iface enp0s8 "$MGMT_MAC"
}
