#!/usr/bin/env bash
# install.sh · vm-template-kit 0.1.0
# 생성 파일이다. 직접 고치지 말고 src/install.sh를 고친 뒤 tools/build.sh를 실행한다.
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
#
# MIT License
#
# Copyright (c) 2026 2davi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
set -euo pipefail

# ═══ src/install.sh ═══
# ─────────────────────────────────────────────────────────────────────────────
# vm-template-kit 설치 스크립트
#
# 템플릿 VM에서 실행한다. OS와 버전을 판별해 그 OS용 vmt-clean, vmt-reid, vmt-nodes와
# 노드 목록 예시(nodes.conf.example)를 내려받고, 같은 태그의 SHA256SUMS로 검사한 뒤 설치한다.
# 명령은 /usr/local/sbin에, 예시 파일은 /etc/vmt에 둔다. 노드 목록(nodes.conf)은 건드리지 않는다.
# SHA256SUMS는 같은 저장소에서 받으므로 전송 오류와 잘린 파일을 막는다. 저장소 자체가 바뀌는 경우는 막지 못한다.
#
# 사용법
#   sudo bash install.sh [--clean [--poweroff]] [--ref <태그나 브랜치>] [--base-url <URL>]
# ─────────────────────────────────────────────────────────────────────────────

VMT_VERSION="0.1.0"
# 지원 대상. 빌드 때 src/os/<os>/<버전> 디렉터리 목록으로 채운다
VMT_TARGETS="debian/13 pve/9 rocky/10 rocky/9 ubuntu/26.04"
# 저장소의 raw 주소. 빌드 때 tools/build.sh의 RAW_BASE로 채운다
BASE_URL="https://raw.githubusercontent.com/2davi/vm-template-kit"
# 내려받을 태그. 기본은 이 설치 스크립트와 같은 버전의 태그다
REF="v$VMT_VERSION"
DEST=/usr/local/sbin
ETC=/etc/vmt
CMDS=(clean reid nodes)
PROG=${0##*/}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
    cat <<EOF
사용법: sudo bash $0 [--clean [--poweroff]] [--ref <태그나 브랜치>] [--base-url <URL>]

템플릿 VM에서 실행한다. OS와 버전을 판별해 vmt-clean, vmt-reid, vmt-nodes를 $DEST에,
노드 목록 예시를 $ETC/nodes.conf.example에 설치한다.
지원 대상: $VMT_TARGETS

  --clean      설치한 뒤 바로 vmt-clean을 실행한다
  --poweroff   --clean과 함께 쓴다. 정리가 끝나면 전원을 끈다
  --ref        내려받을 태그나 브랜치. 기본: $REF
  --base-url   저장소의 raw 주소. 기본: $BASE_URL
  --version    버전을 출력한다
EOF
}

fetch() {  # URL, 저장할 파일
    if command -v curl >/dev/null; then
        curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null; then
        wget -q -O "$2" "$1"
    else
        die "curl이나 wget이 필요하다"
    fi
}

# /etc/os-release(PVE는 pveversion)로 dist/ 아래 디렉터리를 정한다.
# 버전은 디렉터리 단위로 비교한다. "9"는 9.4, 9.6과 맞고 "26.04"는 26.04와 맞는다
detect_target() {
    local id ver t
    [[ -r /etc/os-release ]] || die "/etc/os-release를 읽지 못했다"
    # shellcheck source=/dev/null
    id=$(. /etc/os-release; printf '%s' "${ID:-}")
    # shellcheck source=/dev/null
    ver=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
    if [[ $id == debian ]] && command -v pveversion >/dev/null; then
        id=pve
        ver=$(pveversion | sed -n 's#^pve-manager/\([0-9][0-9]*\)\..*#\1#p')
    fi
    for t in $VMT_TARGETS; do
        [[ ${t%/*} == "$id" ]] || continue
        if [[ $ver == "${t#*/}" || $ver == "${t#*/}".* ]]; then
            printf '%s\n' "$t"
            return 0
        fi
    done
    die "지원하지 않는 OS다: ${id:-알 수 없음} ${ver:-알 수 없음}. 지원 대상: $VMT_TARGETS"
}

main() {
    local clean=0 poweroff=0
    while (( $# )); do
        case $1 in
            -h|--help)    usage; exit 0 ;;
            --version)    printf '%s %s\n' "$PROG" "$VMT_VERSION"; exit 0 ;;
            --clean)      clean=1 ;;
            --poweroff)   poweroff=1 ;;
            --ref)        [[ $# -ge 2 ]] || { usage >&2; exit 2; }; REF=$2; shift ;;
            --ref=*)      REF=${1#*=} ;;
            --base-url)   [[ $# -ge 2 ]] || { usage >&2; exit 2; }; BASE_URL=$2; shift ;;
            --base-url=*) BASE_URL=${1#*=} ;;
            *)            usage >&2; exit 2 ;;
        esac
        shift
    done
    BASE_URL=${BASE_URL%/}
    (( ! poweroff || clean )) || die "--poweroff는 --clean과 함께 쓴다"
    [[ $EUID -eq 0 ]] || die "root 권한이 필요하다. sudo bash $0 ... 로 실행한다"
    command -v sha256sum >/dev/null || die "sha256sum이 없다(coreutils)"

    local target url tmp k want got
    target=$(detect_target) || exit 1
    url=$BASE_URL/$REF/dist
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064  # 지금 정한 경로를 지운다
    trap "rm -rf '$tmp'" EXIT

    say "대상: $target"
    say "출처: $url"
    fetch "$url/SHA256SUMS" "$tmp/SHA256SUMS" || die "내려받기 실패: $url/SHA256SUMS"
    for k in "${CMDS[@]/#/$target/vmt-}" nodes.conf.example; do
        fetch "$url/$k" "$tmp/${k##*/}" || die "내려받기 실패: $url/$k"
        want=$(awk -v p="$k" '$2 == p || $2 == "*" p { print $1; exit }' "$tmp/SHA256SUMS")
        [[ -n $want ]] || die "SHA256SUMS에 $k 항목이 없다"
        got=$(sha256sum "$tmp/${k##*/}" | awk '{ print $1 }')
        [[ $got == "$want" ]] || die "체크섬이 맞지 않다: $k (기대 $want, 실제 $got)"
    done
    # 모두 검사를 통과한 뒤에 설치한다. 일부만 바뀐 상태로 남지 않는다
    for k in "${CMDS[@]}"; do
        install -m 755 -o root -g root "$tmp/vmt-$k" "$DEST/vmt-$k"
    done
    install -d -m 755 "$ETC"
    install -m 644 -o root -g root "$tmp/nodes.conf.example" "$ETC/nodes.conf.example"
    if command -v restorecon >/dev/null; then
        restorecon -F "${CMDS[@]/#/$DEST/vmt-}" "$ETC" "$ETC/nodes.conf.example" >/dev/null 2>&1 || true
    fi
    say "설치했다: $("$DEST/vmt-clean" --version), $("$DEST/vmt-reid" --version), $("$DEST/vmt-nodes" --version)"
    say "노드 목록 예시: $ETC/nodes.conf.example"

    if (( clean )); then
        local -a args=()
        (( poweroff )) && args+=(--poweroff)
        "$DEST/vmt-clean" "${args[@]}"
    else
        say "다음 순서: 노드 목록이 필요하면 sudo $DEST/vmt-nodes, 그다음 sudo $DEST/vmt-clean"
    fi
}

main "$@"
