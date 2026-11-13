#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 전체 테스트 실행기
#
# 사용법: sudo bash tests/run.sh [케이스 이름 접두]     예) sudo bash tests/run.sh debian
# root 권한이 필요하다(마운트 네임스페이스와 overlay). 실제 시스템 파일은 바뀌지 않는다.
# 테스트 대상은 dist/의 생성 파일이다. 먼저 dist/가 src/와 일치하는지 확인한다.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $EUID -eq 0 ]] || { echo "root로 실행한다: sudo bash tests/run.sh" >&2; exit 2; }
command -v unshare >/dev/null || { echo "unshare가 없다(util-linux)" >&2; exit 2; }

# 대역 명령은 PATH로 찾으므로 실행 권한이 있어야 한다. Windows에서 커밋하면 권한이 빠지기 쉽다
for f in "$ROOT"/tests/stubs/* "$ROOT"/tests/stubs-pve/*; do
    [[ -x $f ]] || { echo "실행 권한이 없다: ${f#"$ROOT"/}. git add --chmod=+x로 권한을 기록한다" >&2; exit 2; }
done

bash "$ROOT/tools/build.sh" --check

failed=0
for case_file in "$ROOT"/tests/cases/*.sh; do
    name=${case_file##*/}
    [[ -n ${1:-} && $name != "$1"* ]] && continue
    printf '%s\n' "${name%.sh}"
    if ! unshare --mount --uts --propagation private bash "$ROOT/tests/lib/sandbox.sh" "$ROOT" "$case_file"; then
        failed=1
    fi
done
(( failed == 0 )) && echo "전체 통과" || { echo "실패한 테스트가 있다" >&2; exit 1; }
