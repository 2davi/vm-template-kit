# 변경 기록

이 저장소의 주요 변경을 기록한다. 형식은 [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/)을 따르고, 버전 번호는 [유의적 버전](https://semver.org/lang/ko/)을 따른다. 릴리스 절차는 [docs/DESIGN.md](docs/DESIGN.md)의 버전과 릴리스에 있다.

## [Unreleased]

첫 릴리스 0.1.0으로 묶을 변경이다.

### Added

- `vmt-clean`, `vmt-reid`, `vmt-nodes` 명령. 이전 VirtualBox 지침의 `deb-reid`, `pve-reid`를 대체한다.
- OS 버전 디렉터리 다섯 개: Ubuntu 26.04, Rocky 9, Rocky 10, Debian 13, Proxmox VE 9.
- NAT NIC 하나로 만든 템플릿을 전제로 한 복제본 구성. `vmt-reid`가 노드 구성의 NIC를 복제본에 붙인 NIC에 맞추고 설정 파일을 새로 만든다(netplan `60-vmt.yaml`, NetworkManager `vmt-<이름>.nmconnection`, ifupdown `interfaces.d/vmt`, PVE `vmbr1`부터의 브리지).
- 노드 구성 파일(INI). 템플릿의 노드 목록(`/etc/vmt/nodes.conf`)에 노드마다 호스트명, NIC(이름·MAC·auto 대응, 고정 주소 여럿, DHCP, 주소 없음, 게이트웨이, 경로, MTU), DNS, 추가 디스크, 루트 확장을 적는다. 예시 파일 `nodes.conf.example`.
- 번호 메뉴. `vmt-nodes`는 템플릿에서 노드 목록을 만들고 고치며, `vmt-reid`는 인자 없이 실행하면 노드를 고르고 적용 계획을 보여 준 뒤 적용한다. 값은 입력할 때 검사한다.
- 노드 구성 검사. 형식, 값, 키 조합 오류를 줄 번호와 함께 모두 출력한다(`vmt-nodes --check`). `vmt-clean`도 노드 목록을 검사한다.
- 추가 디스크 구성. 빈 디스크만 GPT 파티션이나 LVM(PV, VG, 볼륨마다 LV)으로 나누고, ext4나 xfs를 만들어 `/etc/fstab`의 UUID 줄(`defaults,nofail`)로 마운트한다. 만든 결과를 기록해 다시 실행할 때 다시 만들지 않는다.
- 루트 디스크 확장(`root_grow`). `growpart`로 루트 파티션을 늘리고 파일 시스템을 늘린다. LVM이면 VG의 남은 공간 전체를 루트 LV에 더한다.
- `vmt-reid`의 `--node`, `--config`, `--check` 옵션. 호스트명과 IP 인자로 NIC 하나를 설정하는 사용법과 `--iface` 옵션.
- 적용 기록 `/etc/vmt/node.conf`.
- Proxmox VE의 두 단계 `vmt-reid`(`--finish`). NIC마다 브리지를 만들고, 노드 구성 규칙(고정 주소 NIC 필수, dhcp·gateway·routes 없음)을 검사한다.
- `install.sh`: OS를 판별해 태그 경로에서 세 명령과 예시 파일을 받고 `SHA256SUMS`로 검사한 뒤 설치한다. 노드 목록은 건드리지 않는다. `--clean`, `--poweroff`, `--ref`, `--base-url` 옵션.
- `src/`를 이어 붙여 `dist/` 단일 파일을 만드는 빌드와 일치 검사(`tools/build.sh --check`). 빌드가 `dist/install.sh`, `dist/nodes.conf.example`, `dist/SHA256SUMS`도 만든다.
- 마운트 네임스페이스 기반 샌드박스 테스트. 가짜 `/sys/class/net`, `/sys/block`과 디스크 명령 대역을 쓴다.
- CI: 빌드 일치 검사, ShellCheck, 샌드박스 테스트. 액션은 전체 커밋 SHA로 고정한다.
- `LICENSE`(MIT, 저작권자 `2davi`). 생성 파일 머리에 저작권 고지, 허가 고지, SPDX 태그를 넣는다.
- `SECURITY.md`, 버그 신고 양식, PR 양식, Dependabot 설정(`github-actions`, 주 1회, 7일 대기), 규칙 세트 정의(`.github/rulesets/`).

[Unreleased]: https://github.com/2davi/vm-template-kit/commits/main
