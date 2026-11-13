#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# src/ → dist/ 빌드
#
# dist/<os>/<버전>/vmt-clean, vmt-reid, vmt-nodes는 아래 순서로 이어 붙인 단일 파일이다.
#   1. src/lib/의 파일                    모든 OS 공통. 순서는 LIBS 배열을 따른다
#   2. src/os/<os>/_family.sh             같은 배포판의 여러 버전이 공유 (있을 때만)
#   3. src/os/<os>/<버전>/_shared.sh      같은 버전의 세 명령이 공유 (있을 때만)
#   4. src/os/<os>/<버전>/clean.sh|reid.sh|nodes.sh
# OS별 파일이 공통 함수(훅)를 같은 이름으로 다시 정의하면 뒤에 붙은 OS별 정의가 쓰인다.
# dist/install.sh는 src/install.sh에 버전, 지원 대상 목록, 저장소 주소를 채운 파일이다.
# dist/nodes.conf.example은 src/nodes.conf.example을 그대로 복사한 파일이다.
# dist/SHA256SUMS는 dist/ 아래 모든 파일의 SHA-256 값이다. install.sh가 내려받은 파일을 이 값으로 검사한다.
# 버전 문자열은 VERSION 파일 하나에서 가져온다.
# 생성 파일은 LICENSE 없이 따로 복사되므로, 머리에 LICENSE의 저작권 고지와 허가 고지, SPDX 태그를 넣는다.
# src/ 조각마다 붙은 SPDX 태그는 빼고 생성 파일 머리에 한 번만 넣는다.
#
# 사용법
#   bash tools/build.sh           dist/를 다시 만든다
#   bash tools/build.sh --check   dist/가 src/와 일치하는지만 검사한다(CI용). 다르면 1로 끝난다
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
MODE=${1:-build}
# install.sh가 내려받는 저장소의 raw 주소. 저장소를 옮기거나 포크하면 이 값을 바꾸고 다시 빌드한다
RAW_BASE=https://raw.githubusercontent.com/2davi/vm-template-kit
# LICENSE 파일의 라이선스 식별자(SPDX). LICENSE를 바꾸면 이 값도 바꾼다
LICENSE_ID=MIT
# 공통 파일을 이어 붙이는 순서. 뒤 파일이 앞 파일의 함수와 변수를 쓴다
LIBS=(common config plan storage menu cmd-clean cmd-reid cmd-nodes)
KINDS=(clean reid nodes)

# 한 파일을 구간 표시 주석과 함께 출력한다.
# 생성 파일 맨 위에 셰뱅과 라이선스 고지가 있으므로 조각의 셰뱅, ShellCheck shell 지시어, SPDX 태그는 뺀다
emit() {
    local rel=${1#"$ROOT"/}
    printf '\n# ═══ %s ═══\n' "$rel"
    sed -e '1{/^#!/d;}' -e '/^# shellcheck shell=bash$/d' \
        -e '/^# SPDX-FileCopyrightText: /d' -e '/^# SPDX-License-Identifier: /d' "$1"
}

# 생성 파일 머리의 라이선스 고지. 저작권자는 LICENSE의 Copyright 줄에서 가져온다.
# 고지 문구의 원본은 LICENSE 하나다
license_header() {
    local holder
    holder=$(sed -n 's/^Copyright (c) //p' "$ROOT/LICENSE")
    [[ -n $holder ]] || { echo "build: LICENSE에 'Copyright (c) ' 줄이 없다" >&2; exit 1; }
    printf '# SPDX-FileCopyrightText: %s\n' "$holder"
    printf '# SPDX-License-Identifier: %s\n' "$LICENSE_ID"
    printf '#\n'
    sed -e 's/^/# /' -e 's/ *$//' "$ROOT/LICENSE"
}

build_one() {  # $1=os 디렉터리 $2=종류(clean|reid|nodes) $3=출력 파일
    local osdir=$1 kind=$2 out=$3 os ver lib
    ver=${osdir##*/}
    os=${osdir%/*}
    os=${os##*/}
    {
        printf '#!/usr/bin/env bash\n'
        printf '# vmt-%s · %s %s · vm-template-kit %s\n' "$kind" "$os" "$ver" "$VERSION"
        printf '# 생성 파일이다. 직접 고치지 말고 src/를 고친 뒤 tools/build.sh를 실행한다.\n'
        license_header
        printf 'set -euo pipefail\n'
        for lib in "${LIBS[@]}"; do
            emit "$ROOT/src/lib/$lib.sh"
        done
        [[ -f $osdir/../_family.sh ]] && emit "$(cd "$osdir/.." && pwd)/_family.sh"
        [[ -f $osdir/_shared.sh ]] && emit "$osdir/_shared.sh"
        emit "$osdir/$kind.sh"
    } | sed "s/@VMT_VERSION@/$VERSION/g" > "$out"
    chmod 755 "$out"
}

# 지원 대상 목록: src/os/<os>/<버전> 디렉터리 이름을 공백으로 이은 값
targets() {
    (cd "$ROOT/src/os" && printf '%s\n' */*/) | sed 's#/$##' | LC_ALL=C sort | paste -sd' ' -
}

build_install() {  # $1=출력 파일
    local out=$1 list
    list=$(targets)
    {
        printf '#!/usr/bin/env bash\n'
        printf '# install.sh · vm-template-kit %s\n' "$VERSION"
        printf '# 생성 파일이다. 직접 고치지 말고 src/install.sh를 고친 뒤 tools/build.sh를 실행한다.\n'
        license_header
        printf 'set -euo pipefail\n'
        emit "$ROOT/src/install.sh"
    } | sed -e "s/@VMT_VERSION@/$VERSION/g" -e "s#@VMT_TARGETS@#$list#g" -e "s#@VMT_RAW_BASE@#$RAW_BASE#g" > "$out"
    chmod 755 "$out"
}

# dist/ 기준 상대 경로로 기록한다. 예) 0123…  ubuntu/26.04/vmt-clean
write_sums() {  # $1=출력 루트
    (cd "$1" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs sha256sum) > "$1/SHA256SUMS"
}

build_all() {  # $1=출력 루트
    local outroot=$1 osdir rel kind
    for osdir in "$ROOT"/src/os/*/*/; do
        osdir=${osdir%/}
        rel=${osdir#"$ROOT"/src/os/}
        mkdir -p "$outroot/$rel"
        for kind in "${KINDS[@]}"; do
            [[ -f $osdir/$kind.sh ]] || { echo "build: $rel/$kind.sh 없음" >&2; exit 1; }
            build_one "$osdir" "$kind" "$outroot/$rel/vmt-$kind"
        done
    done
    build_install "$outroot/install.sh"
    install -m 644 "$ROOT/src/nodes.conf.example" "$outroot/nodes.conf.example"
    write_sums "$outroot"
}

case $MODE in
    build)
        rm -rf "${ROOT:?}/dist"
        build_all "$ROOT/dist"
        find "$ROOT/dist" -type f | sort | sed "s#^$ROOT/##"
        ;;
    --check)
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        build_all "$tmp"
        if diff -r "$tmp" "$ROOT/dist" >/dev/null; then
            echo "dist/가 src/와 일치한다"
        else
            diff -r "$tmp" "$ROOT/dist" | head -40 >&2
            echo "dist/가 src/와 다르다. bash tools/build.sh를 실행하고 커밋한다" >&2
            exit 1
        fi
        ;;
    *)
        echo "사용법: bash tools/build.sh [--check]" >&2
        exit 2
        ;;
esac
