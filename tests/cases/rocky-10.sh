# shellcheck shell=bash
# Rocky Linux 10: 공통 처리는 rocky-9.sh와 같고 ifcfg 처리만 다르다
CLEAN="$ROOT/dist/rocky/10/vmt-clean"
REID="$ROOT/dist/rocky/10/vmt-reid"
NM=/etc/NetworkManager/system-connections
# shellcheck disable=SC2034  # tests/lib/fixture-rocky.sh가 읽는다
TPL_MID=33333333333333333333333333333333

# shellcheck source=tests/lib/fixture-rocky.sh
. "$ROOT/tests/lib/fixture-rocky.sh"

setup() { rocky_fixture 10.2; }

test_clean_warns_on_leftover_ifcfg() {
    fx_file /etc/sysconfig/network-scripts/ifcfg-enp0s3 "DEVICE=enp0s3"
    run bash "$CLEAN"
    assert_rc 0
    assert_out "Rocky 10에서 쓰이지 않는 ifcfg 설정이다"
}

test_clean_refuses_rocky_9() {
    fx_os rocky 9.6
    run bash "$CLEAN"
    assert_rc 1
    assert_out "rocky 10 전용"
}

test_reid_on_clone() {
    clone
    run bash "$REID" rocky10-01.lab.internal 192.168.56.51/24
    assert_rc 0
    assert_line /etc/hostname rocky10-01
    assert_line "$NM/vmt-mgmt.nmconnection" 'address1=192.168.56.51/24'
    assert_line "$NM/vmt-mgmt.nmconnection" 'mac-address=0A:00:27:EE:00:02'
    assert_missing /etc/ssh/ssh_host_ed25519_key
    assert_exists /etc/vmt/reid.done
}

test_reid_refuses_template_vm() {
    bash "$CLEAN" >/dev/null 2>&1
    fx_iface enp0s8 "$MGMT_MAC"
    run bash "$REID" rocky10-01.lab.internal 192.168.56.51/24
    assert_rc 1
    assert_out "템플릿 VM이다"
}
