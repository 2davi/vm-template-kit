# shellcheck shell=bash
# dist/install.sh: OS 판별, 내려받기 주소, SHA256SUMS 검사, 설치, --clean.
# curl 대역이 URL의 /dist/ 뒤 경로를 저장소의 dist/에서 찾아 돌려준다.
INSTALL="$ROOT/dist/install.sh"
export VMT_TEST_DIST="$ROOT/dist"
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
RAW="https://raw.githubusercontent.com/2davi/vm-template-kit/v$VERSION/dist"

setup() {
    rm -f /usr/local/sbin/vmt-clean /usr/local/sbin/vmt-reid /usr/local/sbin/vmt-nodes
    rm -rf /etc/vmt
    mkdir -p /usr/local/sbin
    fx_os ubuntu 26.04
}

test_install_ubuntu() {
    run bash "$INSTALL"
    assert_rc 0
    assert_out "대상: ubuntu/26.04"
    assert_out "출처: $RAW"
    assert_called "curl -fsSL --retry 3 -o"
    assert_called "$RAW/SHA256SUMS"
    assert_called "$RAW/ubuntu/26.04/vmt-clean"
    assert_called "$RAW/ubuntu/26.04/vmt-reid"
    assert_called "$RAW/ubuntu/26.04/vmt-nodes"
    assert_called "$RAW/nodes.conf.example"
    cmp -s /usr/local/sbin/vmt-clean "$ROOT/dist/ubuntu/26.04/vmt-clean" || t_fail "vmt-clean 내용이 dist와 다르다"
    cmp -s /usr/local/sbin/vmt-reid  "$ROOT/dist/ubuntu/26.04/vmt-reid"  || t_fail "vmt-reid 내용이 dist와 다르다"
    cmp -s /usr/local/sbin/vmt-nodes "$ROOT/dist/ubuntu/26.04/vmt-nodes" || t_fail "vmt-nodes 내용이 dist와 다르다"
    cmp -s /etc/vmt/nodes.conf.example "$ROOT/dist/nodes.conf.example" || t_fail "예시 파일 내용이 dist와 다르다"
    assert_eq "$(stat -c %a /usr/local/sbin/vmt-reid)" 755 "권한"
    assert_eq "$(stat -c %a /etc/vmt/nodes.conf.example)" 644 "예시 파일 권한"
    assert_missing /etc/vmt/nodes.conf
    assert_called "restorecon -F /usr/local/sbin/vmt-clean /usr/local/sbin/vmt-reid /usr/local/sbin/vmt-nodes"
    assert_out "설치했다: vmt-clean $VERSION, vmt-reid $VERSION, vmt-nodes $VERSION"
    assert_out "다음 순서: 노드 목록이 필요하면 sudo /usr/local/sbin/vmt-nodes, 그다음 sudo /usr/local/sbin/vmt-clean"
}

test_install_rocky_point_release() {
    fx_os rocky 9.6
    run bash "$INSTALL"
    assert_rc 0
    assert_out "대상: rocky/9"
    cmp -s /usr/local/sbin/vmt-reid "$ROOT/dist/rocky/9/vmt-reid" || t_fail "rocky/9 파일이 아니다"
}

test_install_detects_pve() {
    fx_os debian 13
    PATH="$ROOT/tests/stubs-pve:$PATH" run bash "$INSTALL"
    assert_rc 0
    assert_out "대상: pve/9"
}

test_install_refuses_unsupported_os() {
    fx_os ubuntu 24.04
    run bash "$INSTALL"
    assert_rc 1
    assert_out "지원하지 않는 OS다: ubuntu 24.04"
    assert_missing /usr/local/sbin/vmt-clean
}

# 한 파일이라도 체크섬이 맞지 않으면 아무것도 설치하지 않는다
test_install_refuses_checksum_mismatch() {
    touch "$VMT_TEST_SB/curl-corrupt"
    run bash "$INSTALL"
    assert_rc 1
    assert_out "체크섬이 맞지 않다: ubuntu/26.04/vmt-reid"
    assert_missing /usr/local/sbin/vmt-clean
    assert_missing /usr/local/sbin/vmt-reid
    assert_missing /usr/local/sbin/vmt-nodes
    assert_missing /etc/vmt/nodes.conf.example
}

# 설치는 노드 목록(nodes.conf)을 건드리지 않는다
test_install_keeps_nodes_conf() {
    fx_file /etc/vmt/nodes.conf "[node keep-me]"
    run bash "$INSTALL"
    assert_rc 0
    assert_line /etc/vmt/nodes.conf "[node keep-me]"
}

test_install_download_failure() {
    touch "$VMT_TEST_SB/curl-offline"
    run bash "$INSTALL"
    assert_rc 1
    assert_out "내려받기 실패: $RAW/SHA256SUMS"
}

test_install_ref_and_base_url() {
    run bash "$INSTALL" --ref main --base-url https://mirror.example.test/vm-template-kit/
    assert_rc 0
    assert_called "https://mirror.example.test/vm-template-kit/main/dist/ubuntu/26.04/vmt-clean"
    run bash "$INSTALL" --ref=v0.0.9 --base-url=https://mirror.example.test/x
    assert_called "https://mirror.example.test/x/v0.0.9/dist/SHA256SUMS"
}

test_install_option_checks() {
    run bash "$INSTALL" --poweroff;   assert_rc 1; assert_out "--poweroff는 --clean과 함께 쓴다"
    run bash "$INSTALL" --bogus;      assert_rc 2
    run bash "$INSTALL" --ref;        assert_rc 2
    run bash "$INSTALL" --version;    assert_rc 0; assert_out "install.sh $VERSION"
    assert_missing /usr/local/sbin/vmt-clean
}

# --clean은 설치한 vmt-clean을 이어서 실행한다
test_install_then_clean() {
    rm -rf /etc/netplan /etc/cloud
    fx_hostname ubuntu-tpl
    fx_file /etc/hosts "127.0.0.1 localhost
127.0.1.1 ubuntu-tpl"
    fx_iface enp0s3 08:00:27:aa:00:01 10.0.2.15/24
    fx_route enp0s3
    fx_machine_id 11111111111111111111111111111111
    fx_ssh_keys
    run bash "$INSTALL" --clean --poweroff
    assert_rc 0
    assert_out "== vmt-clean 결과 =="
    assert_eq "$(tpl_env VMT_TPL_IFACE)" enp0s3
    assert_called "systemctl poweroff"
}
