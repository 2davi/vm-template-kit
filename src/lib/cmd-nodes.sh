# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 2davi
# SPDX-License-Identifier: MIT
# ─────────────────────────────────────────────────────────────────────────────
# vmt-nodes: 노드 목록 만들기와 검사
#
# 템플릿에서 실행한다. 노드 목록(/etc/vmt/nodes.conf)을 메뉴로 만들고 고치거나,
# 손으로 고친 파일을 검사한다. 복제본의 vmt-reid가 이 목록에서 노드를 골라 적용한다.
# ─────────────────────────────────────────────────────────────────────────────

vmt_nodes_usage() {
    cat <<EOF
사용법:
  sudo $0 [--config <파일>]            메뉴에서 노드 목록을 만들고 고친다
  $0 --check [--config <파일>]         노드 목록을 검사하고 노드마다 한 줄로 요약한다
  $0 --show <노드> [--config <파일>]   노드 하나의 구성을 [defaults] 값을 합쳐 출력한다

노드 목록 기본 위치: $VMT_NODES_CONF
형식 설명: $VMT_NODES_CONF.example
템플릿에 노드 목록을 두면 복제본에서 vmt-reid를 인자 없이 실행해 노드를 고를 수 있다.
목록을 고친 뒤에는 vmt-clean을 다시 실행하고 스냅샷(부모 디스크)을 다시 만든다.

  --version    버전을 출력한다
EOF
}

vmt_nodes_main() {
    local file=$VMT_NODES_CONF mode=menu show="" n
    while (( $# )); do
        case $1 in
            -h|--help) vmt_nodes_usage; exit 0 ;;
            --version) printf '%s %s\n' "$PROG" "$VMT_VERSION"; exit 0 ;;
            --check)   mode=check ;;
            --show|--config)
                [[ $# -ge 2 ]] || { vmt_nodes_usage >&2; exit 2; }
                if [[ $1 == --show ]]; then mode=show; show=$2; else file=$2; fi
                shift
                ;;
            --show=*)   mode=show; show=${1#*=} ;;
            --config=*) file=${1#*=} ;;
            *) vmt_nodes_usage >&2; exit 2 ;;
        esac
        shift
    done
    os_require
    case $mode in
        check)
            [[ -f $file ]] || vmt_die "노드 목록이 없다: $file"
            vmt_cfg_load_checked "$file"
            vmt_say "$file: 오류 없음, 노드 $(wc -w <<<"$CFG_NODES")개"
            for n in $CFG_NODES; do
                printf '  %-16s %s\n' "$n" "$(vmt_cfg_node_brief "$n")"
            done
            ;;
        show)
            [[ -f $file ]] || vmt_die "노드 목록이 없다: $file"
            vmt_cfg_load_checked "$file"
            [[ " $CFG_NODES " == *" $show "* ]] || vmt_die "노드가 없다: $show. 있는 노드: ${CFG_NODES:-없음}"
            vmt_cfg_render "$show" | sed '1{/^$/d;}'
            ;;
        menu)
            vmt_require_root
            vmt_nodes_menu "$file"
            ;;
    esac
}
