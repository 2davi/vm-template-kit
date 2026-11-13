#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 마운트·UTS 네임스페이스 안에서 케이스 파일 하나를 실행한다. tests/run.sh가 부른다.
# 인자: 저장소 루트, 케이스 파일
# 케이스 파일은 setup 함수와 test_로 시작하는 함수들을 정의한다.
# 테스트마다 파일 트리를 새로 만들고(sb_reset), setup을 실행한 뒤 테스트 함수를 하위 셸에서 실행한다.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT=$1
CASE=$2
export PATH="$ROOT/tests/stubs:$PATH"

# shellcheck source=tests/lib/harness.sh
. "$ROOT/tests/lib/harness.sh"
# shellcheck source=/dev/null
. "$CASE"

pass=0
fail=0
trap sb_umount EXIT
sb_mount
for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    sb_reset
    if ( T_FAILED=0; setup; "$t"; exit "$T_FAILED" ); then
        printf '  ok    %s\n' "$t"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$t"
        fail=$((fail + 1))
    fi
done
printf '  %s: 통과 %d, 실패 %d\n' "${CASE##*/}" "$pass" "$fail"
(( fail == 0 ))
