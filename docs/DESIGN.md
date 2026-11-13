# vm-template-kit 설계

이 문서는 저장소의 구성 원칙과 관리 절차를 정한다. 사용법은 [README.md](../README.md)가 맡고, 하이퍼바이저 쪽 절차(VM 생성, 스냅샷, 부모 디스크, 복제, 어댑터와 스위치)는 [docs.the2davi.dev의 하이퍼바이저 문서](https://docs.the2davi.dev/notes/linux/hypervisor/)가 맡는다.

## 목적과 범위

리눅스 VM 템플릿에서 링크된 복제본을 만들 때 게스트 안에서 해야 하는 작업을 명령 세 개로 고정한다. 템플릿 쪽에서는 `vmt-nodes`가 노드 목록을 만들고 `vmt-clean`이 템플릿을 정리한다. 복제본 쪽에서는 `vmt-reid`가 노드 하나를 골라 식별 정보를 새로 만들고 NIC와 디스크를 구성한다. 세 명령은 `install.sh`가 저장소의 태그 경로에서 내려받아 설치한다.

복제본마다 달라지는 값은 스크립트에 두지 않는다. 사용자는 노드 구성 파일에 값을 적거나 메뉴로 입력하고, 스크립트는 그 값을 검사한 뒤 OS별 설정 파일로 옮긴다.

| 구분 | 포함 | 제외 |
| --- | --- | --- |
| 실행 위치 | 게스트 OS 안 | 호스트(VirtualBox, Hyper-V) 명령. 문서에 명령 단위로 둔다 |
| OS | 실제로 설치해 템플릿으로 쓰는 버전 | 써 본 적 없는 버전 |
| 템플릿 네트워크 | NAT NIC 하나. DHCP(PVE는 VirtualBox NAT 정적 주소) | 템플릿에 관리 IP를 두는 구성 |
| 복제본 NIC | 노드 구성의 NIC. IPv4 고정 주소(여럿 가능), DHCP, 주소 없음. 게이트웨이, 경로, MTU, DNS | IPv6 고정 주소, 본드, VLAN, 브리지(PVE 제외) |
| 복제본 디스크 | 빈 추가 디스크의 GPT 파티션과 LVM, ext4와 xfs, `/etc/fstab` 마운트. 루트 파티션과 파일 시스템 확장 | 데이터가 있는 디스크 재구성, 루트 디스크 파티션 재배치, 스왑, 암호화, RAID |
| 노드 구성 입력 | INI 파일(템플릿의 노드 목록)과 번호 메뉴 | YAML, 전체 화면 TUI(dialog, whiptail) |
| 초기화 방식 | 복제본에서 명령 한 번 실행 | cloud-init과 시드 ISO 기반 자동 초기화(보류, 설계 결정 참고) |
| Proxmox VE | VirtualBox 위의 빈 단독 노드 | Hyper-V 위의 PVE, 클러스터 노드, VM이나 CT가 있는 노드 |

스크립트는 하이퍼바이저를 구분하지 않는다. 기본 경로로 NAT 인터페이스를 찾고, 노드 구성의 NIC를 이름, MAC, 남은 후보 순으로 물리 NIC에 맞추고, MAC 주소로 템플릿 VM을 가려낸다. 그래서 VirtualBox의 `enp0s3`, `enp0s8`과 Hyper-V의 `eth0`, `eth1`에서 같은 파일이 동작한다.

Hyper-V 위의 PVE를 범위에서 뺀 이유는 NAT 주소다. PVE 설치 관리자는 `vmbr0`에 정적 주소를 쓴다. Hyper-V의 Default Switch는 대역을 바꿀 수 없고, 호스트 상황에 따라 `192.168.0.0/16`이나 `172.17.0.0`~`172.31.255.255` 안에서 대역을 골라 쓴다([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/48268/change-hyper-v-default-switch-ip-address-range.html), [Tech Community](https://techcommunity.microsoft.com/t5/windows-insider-program/hyper-v-default-switch-ip-address-range-change-ver-1809-build/m-p/261431)). VirtualBox NAT는 어댑터 1에 늘 `10.0.2.0/24`를 준다.

## 저장소 구조

```text
vm-template-kit/
├── VERSION                     버전 번호의 유일한 원본
├── README.md
├── CHANGELOG.md
├── LICENSE                     MIT 라이선스 전문. 생성 파일 머리 고지의 원본
├── SECURITY.md                 지원 버전과 취약점 신고 경로
├── docs/DESIGN.md              이 문서
├── src/
│   ├── lib/                    모든 OS 공통. 이어 붙이는 순서대로 아래와 같다
│   │   ├── common.sh           출력, 값 검사, /etc/hosts, 파일, 인터페이스, 식별 정보, 기본 훅
│   │   ├── config.sh           노드 구성 파일(INI) 읽기, 검사, 쓰기
│   │   ├── plan.sh             노드 구성을 하드웨어에 맞춘 적용 계획
│   │   ├── storage.sh          추가 디스크와 루트 확장 적용
│   │   ├── menu.sh             번호 메뉴
│   │   └── cmd-clean.sh, cmd-reid.sh, cmd-nodes.sh   명령 본체
│   ├── install.sh              설치 스크립트 소스
│   ├── nodes.conf.example      노드 목록 예시와 형식 설명
│   └── os/
│       ├── ubuntu/26.04/       _shared.sh, clean.sh, reid.sh, nodes.sh
│       ├── rocky/_family.sh    Rocky 9와 10이 공유하는 정의
│       ├── rocky/9/
│       ├── rocky/10/
│       ├── debian/13/
│       └── pve/9/
├── dist/
│   ├── <os>/<버전>/            vmt-clean, vmt-reid, vmt-nodes 생성 파일
│   ├── install.sh              설치 스크립트 생성 파일
│   ├── nodes.conf.example      src/nodes.conf.example 복사본
│   └── SHA256SUMS              dist/ 아래 모든 파일의 SHA-256 값
├── tools/build.sh              src/ → dist/ 빌드와 일치 검사
├── tests/
│   ├── run.sh                  전체 실행기
│   ├── lib/                    하네스, 샌드박스 실행기, 공유 고정 데이터
│   ├── cases/                  OS 버전마다 케이스 파일 하나, 노드 구성 케이스, 설치 스크립트 케이스
│   ├── stubs/                  시스템 명령 대역
│   └── stubs-pve/              Proxmox VE 명령 대역
├── .github/
│   ├── workflows/ci.yml        빌드 일치 검사, ShellCheck, 샌드박스 테스트
│   ├── dependabot.yml          워크플로 액션의 버전 갱신 PR
│   ├── rulesets/               규칙 세트 정의. GitHub 설정에서 가져온다
│   ├── ISSUE_TEMPLATE/         버그 신고 양식, 이슈 선택 화면 설정
│   └── pull_request_template.md
├── .gitattributes
└── .editorconfig
```

## 버전 디렉터리 정책

디렉터리 하나가 OS의 호환 단위 하나다. 같은 디렉터리 안의 버전은 네트워크 설정 형식, SSH 호스트 키 생성 방식, DHCP 클라이언트가 같아야 한다.

| OS | 디렉터리 | 호환 단위 | 판정 기준 |
| --- | --- | --- | --- |
| Ubuntu Server | `ubuntu/26.04` | LTS 릴리스 | `/etc/os-release`의 `VERSION_ID`가 `26.04` |
| Rocky Linux | `rocky/9`, `rocky/10` | 메이저 버전 | `VERSION_ID`가 `9`나 `9.`으로 시작 |
| Debian | `debian/13` | 메이저 버전 | `VERSION_ID`가 `13` |
| Proxmox VE | `pve/9` | 메이저 버전 | `pveversion`의 `pve-manager/9.x` |

판정은 각 디렉터리의 `_shared.sh`에 있는 `os_require`가 한다. 맞지 않으면 아무것도 바꾸지 않고 멈춘다. Proxmox VE도 `/etc/os-release`가 Debian 13이므로, Debian 13 스크립트는 `pveversion`이 있으면 거부하고 PVE 스크립트를 쓰라고 안내한다. `install.sh`도 같은 기준으로 디렉터리를 고른다.

새 디렉터리는 그 버전을 실제로 설치해 템플릿을 만들 때만 추가한다. 써 보지 않은 버전을 미리 만들면 검증하지 않은 코드가 지원 범위에 들어간다.

코드는 네 단계로 공유한다.

| 단계 | 파일 | 범위 |
| --- | --- | --- |
| 1 | `src/lib/*.sh` | 모든 OS |
| 2 | `src/os/<os>/_family.sh` | 같은 배포판의 여러 버전(현재 Rocky 9, 10) |
| 3 | `src/os/<os>/<버전>/_shared.sh` | 같은 버전의 세 명령 |
| 4 | `src/os/<os>/<버전>/clean.sh`, `reid.sh`, `nodes.sh` | 명령 하나 |

## 단일 파일 빌드

VM 안에는 파일 하나만 넣어 바로 실행하고, 공통 코드는 저장소에 한 벌만 두려고 빌드 단계를 둔다. `tools/build.sh`가 공유 단계 순서대로 파일을 이어 붙여 `dist/<os>/<버전>/vmt-clean`, `vmt-reid`, `vmt-nodes`를 만들고, `VERSION` 값을 넣는다. `src/lib/`의 파일 순서는 `tools/build.sh`의 `LIBS` 배열이 정한다. 세 명령은 같은 공통 코드를 모두 포함하고, 마지막 조각(`clean.sh`, `reid.sh`, `nodes.sh`)이 어느 명령의 본체를 부를지 정한다.

| 방식 | 배포 | 공통 코드 | 판단 |
| --- | --- | --- | --- |
| OS별 독립 스크립트 | 파일 하나 | OS마다 복사본. 한쪽만 고치는 실수가 생긴다 | 제외 |
| 실행 중 `common.sh`를 `source` | 파일 여러 개. 설치 경로에 의존한다 | 한 벌 | 제외 |
| 빌드로 이어 붙이기 | 파일 하나 | 한 벌 | 채택 |

빌드는 같은 단계에서 `dist/install.sh`, `dist/nodes.conf.example`, `dist/SHA256SUMS`도 만든다. `install.sh`에는 버전, 지원 대상 목록(`src/os/<os>/<버전>` 디렉터리 이름), 저장소의 raw 주소를 채운다. raw 주소는 `tools/build.sh`의 `RAW_BASE` 한 곳에 둔다. 저장소를 옮기거나 포크하면 이 값을 바꾸고 다시 빌드한다.

`dist/`는 생성 파일이지만 커밋한다. 태그 단위로 배포본이 고정되고, `install.sh`가 태그 경로의 raw 주소에서 받는다. CI가 `bash tools/build.sh --check`로 `dist/`와 `src/`가 다르면 실패시킨다. 생성 파일 머리에는 직접 고치지 말라는 주석이 들어간다.

빌드는 조각마다 붙은 셰뱅, ShellCheck `shell` 지시어, SPDX 태그를 빼고, 조각 경계에 `# ═══ src/... ═══` 주석을 넣는다. 오류가 난 줄을 생성 파일에서 찾으면 이 주석으로 원래 파일을 알 수 있다.

생성 파일은 `LICENSE` 없이 따로 복사된다. MIT 라이선스는 모든 복사본에 저작권 고지와 허가 고지를 넣도록 요구하므로, 빌드가 생성 파일 머리에 `LICENSE` 전문을 주석으로 넣고 SPDX 태그 두 줄(`SPDX-FileCopyrightText`, `SPDX-License-Identifier`)을 붙인다. 저작권자는 `LICENSE`의 `Copyright (c)` 줄에서 가져오므로 고지 문구의 원본은 `LICENSE` 하나다. `src/`의 셸 파일도 머리에 같은 SPDX 태그를 둔다([REUSE](https://reuse.software/tutorial/)).

## 설치 스크립트

`install.sh`는 템플릿 VM에서 처음 한 번 실행한다. 동작 순서는 다음과 같다.

1. root 권한과 `sha256sum`을 확인한다.
2. `/etc/os-release`(PVE는 `pveversion`)로 `dist/` 아래 디렉터리를 정한다. 지원 대상이 아니면 멈춘다.
3. `<RAW_BASE>/<태그>/dist/SHA256SUMS`, 세 명령, `nodes.conf.example`을 임시 디렉터리에 받는다. curl이 없으면 wget을 쓴다.
4. 받은 파일을 `SHA256SUMS` 값과 비교한다. 하나라도 다르면 아무것도 설치하지 않는다.
5. 모두 통과하면 명령은 `/usr/local/sbin`에 권한 755로, 예시 파일은 `/etc/vmt/nodes.conf.example`에 권한 644로 설치하고, `restorecon`이 있으면 SELinux 라벨을 맞춘다. 노드 목록(`/etc/vmt/nodes.conf`)은 건드리지 않는다.
6. `--clean`이면 설치한 `vmt-clean`을 이어서 실행한다.

기본 태그는 설치 스크립트 자신의 버전(`v<VERSION>`)이다. 그래서 `v0.1.0` 경로에서 받은 설치 스크립트는 `v0.1.0`의 명령을 설치한다. `--ref`로 다른 태그나 브랜치를, `--base-url`로 다른 저장소를 지정할 수 있다.

`SHA256SUMS`는 명령과 같은 저장소에서 받는다. 이 검사는 전송 오류와 잘린 파일을 막지만, 저장소의 파일과 `SHA256SUMS`가 함께 바뀌는 경우는 막지 못한다. 그래서 릴리스를 불변 릴리스(immutable release)로 발행한다(버전과 릴리스). 불변 릴리스로 발행한 태그는 다른 커밋으로 옮기거나 지울 수 없으므로, 발행한 뒤에는 태그 경로의 파일이 바뀌지 않는다. 태그와 이름이 같은 브랜치가 생겼을 때 raw 주소가 어느 쪽을 가리키는지는 확인하지 않았으므로, `v*` 이름의 브랜치는 규칙 세트로 만들지 못하게 한다. 발행 전에 저장소 계정이 탈취된 경우는 여전히 막지 못한다([Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)).

설치 스크립트 자신은 사용자가 `sha256sum -c --ignore-missing SHA256SUMS`로 검사한 뒤 실행한다. 릴리스에 첨부한 `SHA256SUMS`가 그 릴리스에서 나온 파일인지는 호스트에서 GitHub CLI의 `gh release verify-asset`으로 확인할 수 있다([Verifying the integrity of a release](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity)).

## 명령 계약

### 공통 규칙

- root 권한이 필요하다. 아니면 실행한 경로를 넣어 `sudo <경로>`로 안내한다.
- 종료 코드는 0(성공), 1(거부나 실패), 2(사용법 오류)다.
- 메시지는 `<명령>: <내용>` 형식이고 경고는 `<명령>: 경고: <내용>` 형식이다. 모두 표준 오류로 나간다.
- 기존 파일을 고칠 때는 처음 원본을 `/var/lib/vmt/reid-backup` 아래에 한 번만 보관하고, 매번 그 원본에서 새 내용을 만든다. 새로 만드는 NIC 설정 파일은 매번 처음부터 다시 쓴다. 그래서 중간에 실패한 뒤 같은 명령(값을 고친 명령 포함)을 다시 실행해도 결과가 같다.
- 기존 파일 내용은 덮어쓰기로 바꾼다. inode가 유지되어 권한, 소유자, SELinux 라벨이 그대로 남는다.

### vmt-clean

템플릿 구성을 끝내고 스냅샷(VirtualBox)이나 부모 디스크(Hyper-V)를 만들기 직전에 실행한다. 사전 검사를 모두 통과해야 무엇이든 바꾼다.

사전 검사는 다음 순서로 한다.

1. OS와 버전(`os_require`)
2. `vmt-reid`를 실행한 복제본이 아닌지(`/etc/vmt/reid.done`)
3. `vmt-reid`가 만든 NIC 설정이 남아 있지 않은지(`os_network_present`)
4. 노드 목록(`/etc/vmt/nodes.conf`)이 있으면 형식과 값에 오류가 없는지. 오류는 줄 번호와 함께 모두 출력한다
5. 호스트명 형식. FQDN은 `/etc/hosts`에서 짧은 호스트명과 같은 줄의 `<호스트명>.`으로 시작하는 이름을 쓰고, 없으면 `/etc/hostname`에 적힌 FQDN을 쓴다. 둘 다 없으면 FQDN 없이 기록한다
6. 기본 경로를 가진 인터페이스가 정확히 하나인지. 이 인터페이스를 NAT 인터페이스로 기록한다
7. 템플릿 판별용 MAC(`os_template_mac`)
8. NAT 말고 다른 물리 NIC가 있는지. 있으면 경고만 한다. 복제본이 물려받아 `interface = auto`의 후보가 되기 때문이다
9. OS별 점검(`os_clean_checks`)

검사를 통과하면 `/etc/vmt/template.env`에 템플릿 정보를 기록하고 아래 상태를 지운다.

| 대상 | OS | 이유 |
| --- | --- | --- |
| 저널 | 공통 | 템플릿에서 쌓인 로그 |
| `/var/lib/systemd/random-seed` | 공통 | 복제본이 같은 난수 시드로 시작하지 않게 한다. 서비스를 먼저 멈춰 종료 때 다시 저장하지 않게 한다 |
| `/var/lib/systemd/credential.secret` | 공통 | 호스트마다 달라야 하는 자격 증명 암호화 키 |
| root와 sudo 사용자의 셸 기록 | 공통 | 템플릿 작업 기록 |
| `/var/log/installer/autoinstall-user-data` | Ubuntu | 계정과 비밀번호 해시 |
| `/var/log/installer/cdebconf` | Debian | 설치 응답 데이터베이스. 민감한 응답이 남을 수 있다 |
| `/root/anaconda-ks.cfg`, `/root/original-ks.cfg` | Rocky | 계정과 비밀번호 해시 |
| keyfile의 MAC 고정 줄 | Rocky | MAC이 바뀐 복제본에서 NAT 프로필이 올라오지 않는다. `interface-name`이 없는 프로필은 경고한다 |
| NetworkManager 임대 기록, v1 `secret_key` | Rocky | v1 키는 machine-id와 섞이지 않는다 |
| dhcpcd 임대 기록 | Debian | 템플릿이 받은 주소 |
| 패키지 캐시 | 전부 | 템플릿 크기 |

machine-id와 SSH 호스트 키는 지우지 않는다. 템플릿은 고유한 식별 정보를 가진 정상 노드로 남는다. 템플릿을 다시 켜서 패키지를 갱신하거나 설정을 고친 뒤 `vmt-clean`을 다시 실행해도 된다. 템플릿에 SSH로 접속할 때는 VirtualBox NAT 포트 포워딩이나 Hyper-V Default Switch의 주소를 쓴다.

### vmt-nodes

템플릿에서 노드 목록을 만들고 검사한다. 노드 목록은 복제본의 `vmt-reid`가 읽는다.

| 실행 | 동작 |
| --- | --- |
| `vmt-nodes` | 번호 메뉴로 공통값, 노드, NIC, 디스크를 만들고 고친다. 저장(`s`)할 때 전체를 검사하고, 오류가 있으면 저장하지 않는다. 저장하면 바로 전 파일을 `.bak`으로 하나 남긴다 |
| `vmt-nodes --check` | 파일을 검사하고 노드마다 한 줄로 요약한다. 오류가 있으면 줄 번호와 함께 모두 출력하고 1로 끝난다 |
| `vmt-nodes --show <노드>` | 노드 하나를 `[defaults]` 값을 합쳐 출력한다 |

`--config <파일>`로 다른 파일을 다룬다. 메뉴로 저장한 파일은 다시 쓴 파일이라 손으로 적은 주석이 남지 않는다. 형식 설명은 예시 파일(`/etc/vmt/nodes.conf.example`)이 맡는다. 노드 목록을 고친 뒤에는 `vmt-clean`을 다시 실행하고 스냅샷이나 부모 디스크를 다시 만든다. 복제본은 디스크를 만들 때의 노드 목록을 물려받기 때문이다.

### 노드 구성 파일

형식은 INI다. bash와 awk만으로 읽을 수 있고, 줄 단위라 오류 위치를 줄 번호로 알려 줄 수 있다.

| 구역 | 뜻 | 키 |
| --- | --- | --- |
| `[defaults]` | 모든 노드의 기본값. 노드에 같은 키가 없을 때 쓴다 | `domain`, `dns`, `search`, `root_grow` |
| `[node <이름>]` | 노드 하나. 이름은 호스트명 규칙을 따르고, `hostname`이 없으면 호스트명으로 쓴다 | `hostname`, `domain`, `dns`, `search`, `root_grow` |
| `[nic <이름>]` | 바로 앞 `[node]`에 속한 NIC 하나 | `interface`, `method`, `address`, `gateway`, `mtu`, `routes` |
| `[disk <이름>]` | 바로 앞 `[node]`에 속한 볼륨 하나 | `device`, `size`, `fs`, `mount`, `options`, `label`, `lvm`, `vg`, `disk_size` |

읽기 규칙은 다음과 같다.

- 줄 첫머리의 `#`, `;`는 주석이다. 값 뒤에 공백과 `#`, `;`가 오면 그 뒤도 주석이다. 값은 따옴표로 감쌀 수 있다.
- 구역 종류와 키 이름은 대소문자를 가리지 않는다. 여러 값은 쉼표로 구분한다. CRLF 줄 끝과 UTF-8 BOM은 지운다.
- 알 수 없는 구역이나 키, 겹치는 키와 이름은 오류다. 잘못된 구역 머리 뒤의 키는 따로 오류를 내지 않는다. 같은 원인의 오류가 쌓이지 않게 하기 위해서다.
- 빈 값은 적지 않은 것으로 본다. 예시 파일처럼 키만 남겨 둘 수 있다.

읽기는 awk가 파일을 탭으로 구분한 레코드(구역 머리, 키와 값, 형식 오류)로 바꾸고 bash가 연관 배열 하나(`CFG`)에 담는다. 검사는 세 단계로 나뉜다.

| 단계 | 함수 | 검사 | 실행 위치 |
| --- | --- | --- | --- |
| 형식 | `vmt_cfg_load` | 구역과 키 이름, 중복, 줄 형식 | 모든 명령 |
| 값과 조합 | `vmt_cfg_validate` | 값 하나의 형식(`vmt_value_error`), 키 사이의 조합, OS별 규칙(`os_cfg_validate_node`) | 모든 명령, 메뉴의 값 입력 |
| 하드웨어 대조 | `vmt_plan_build` | NIC와 디스크가 이 VM에 있는지, 디스크가 비어 있는지, 필요한 명령이 있는지 | 복제본의 `vmt-reid` |

키 사이의 조합 규칙은 다음과 같다.

- `method = static`이면 `address`가 있어야 한다. `dhcp`와 `off`에는 `address`, `gateway`를 쓰지 않고, `off`에는 `routes`도 쓰지 않는다.
- `gateway`는 노드마다 NIC 하나에만 쓰고, 그 NIC의 대역 안에 있어야 한다. 고정 주소 NIC의 경로 게이트웨이도 그 NIC의 대역 안에 있어야 한다.
- `interface = auto`는 노드마다 NIC 하나에만 쓴다. 같은 이름이나 MAC을 두 NIC에 쓰지 않는다. NIC끼리 대역이 겹치면 안 된다.
- `fs = none`이면 `mount`, `label`을 쓰지 않고, 아니면 `mount`가 있어야 한다. 마운트 경로는 노드 안에서 겹치지 않는다.
- 같은 `device`의 볼륨은 `lvm`, `vg`, `disk_size` 값이 같아야 한다. `size`가 없는 볼륨은 그 디스크의 마지막 볼륨이어야 한다.
- 노드에 직접 적은 `dns`, `search`는 붙일 NIC(`static` 또는 `dhcp`)가 있어야 한다. `[defaults]`에서 온 값은 붙일 NIC가 없으면 쓰지 않는다.

### vmt-reid

복제본을 처음 켠 뒤 콘솔에서 한 번 실행한다. 적용할 노드를 정하는 방법은 세 가지다.

| 실행 | 노드 |
| --- | --- |
| `vmt-reid` | 메뉴에서 노드 목록의 노드를 고르거나 새로 만든다. 고친 내용은 노드 목록에 쓰지 않는다 |
| `vmt-reid --node <노드> [--config <파일>]` | 노드 목록(기본 `/etc/vmt/nodes.conf`)의 노드 |
| `vmt-reid --config <파일>` | 노드가 하나뿐인 구성 파일의 노드 |
| `vmt-reid [--iface <인터페이스>] <FQDN 또는 호스트명> <IP/접두>` | NIC 하나(`mgmt`)를 고정 주소로 두는 노드를 즉석에서 만든다. 노드 목록은 읽지 않는다 |

`--check`를 더하면 계획만 출력하고 아무것도 바꾸지 않는다. 메뉴에서는 노드를 고르면 계획을 먼저 보여 주고, 적용(`a`)을 고를 때까지 바꾸지 않는다. 계획이 이 VM에 맞지 않으면 적용을 고를 수 없고, 고치기(`e`)로 노드를 고친 뒤 다시 계획을 본다.

사전 검사를 하나라도 통과하지 못하면 아무것도 바꾸지 않는다.

| 검사 | 막는 상황 |
| --- | --- |
| 완료 기록(`/etc/vmt/reid.done`) | 같은 복제본에서 두 번 실행 |
| 템플릿 기록과 형식 번호 | `vmt-clean` 없이 만든 템플릿, 다른 형식의 기록 |
| 템플릿 MAC이 보이는 인터페이스 | 템플릿 VM에서 실행. 복제 기능은 MAC을 새로 만들므로 템플릿 MAC이 보이면 템플릿 VM이다 |
| `/etc/machine-id`가 마운트 지점인지 | 첫 부팅 처리가 끝나지 않은 상태 |
| NAT 인터페이스에 기본 경로가 있는지 | NAT DHCP 실패, 첫 번째 어댑터가 NAT가 아닌 구성, Hyper-V에서 NIC 순서가 바뀐 상태 |
| 노드 구성 검사 | 형식 오류, 값 오류, 조합 오류. 노드 목록의 오류는 다른 노드의 것이라도 거부한다 |
| 템플릿과 같은 호스트명 | 템플릿과 충돌 |
| NIC 대응 | 없는 NIC, NAT NIC를 가리키는 구성, 같은 NIC를 두 번 가리키는 구성, auto 후보가 없거나 여럿인 구성 |
| 고정 주소가 NAT 쪽 대역과 겹치는지 | 경로 충돌 |
| 추가 디스크 | 없는 디스크, 비어 있지 않은 디스크, 크기 확인(`disk_size`) 불일치, 크기 합계 초과, 비어 있지 않은 마운트 경로, 필요한 명령 없음 |
| 루트 확장 | ext4, xfs가 아닌 루트, `growpart` 없음, `growpart -N` 오류 |
| `/etc/hosts`의 새 이름과 새 IP | 새 이름이 다른 IP로, 새 IP가 다른 이름으로 이미 있는 줄 |
| OS별 점검(`os_reid_checks`) | 템플릿 설정이 노드 구성의 NIC도 맡는 구성 |

새 IP를 다른 VM이 쓰고 있는지는 게스트에서 확인하지 않는다. NIC에 아직 주소가 없으므로 게스트의 확인 요청은 기본 경로(NAT)로 나간다. 확인은 복제본을 켜기 전에 호스트에서 그 대역 쪽으로 한다(하이퍼바이저 문서의 복제 절차).

검사를 통과하면 다음 순서로 바꾼다.

1. `/etc/hostname`, `/etc/hosts`, `/etc/mailname`, postfix `main.cf`. 바꾼 뒤 새 이름이 새 IP에만 있고 템플릿 이름이 없는지 검사한다
2. NIC 설정 파일(`os_write_network`)
3. OS별 반영과 검사(`os_after_net_edit`)
4. 추가 디스크: 파티션, LVM, 파일 시스템, `/etc/fstab`, 마운트
5. 루트 디스크 확장
6. machine-id 재생성. `/run/machine-id`와 링크가 아닌 D-Bus machine-id 파일도 지운다. `systemd-machine-id-setup`은 이 두 곳에서 옛 값을 다시 가져오기 때문이다([machine-id(5)](https://www.freedesktop.org/software/systemd/man/latest/machine-id.html), [systemd-machine-id-setup(1)](https://www.freedesktop.org/software/systemd/man/latest/systemd-machine-id-setup.html))
7. SSH 호스트 키(`os_ssh_hostkeys`)
8. DHCP 클라이언트 상태(`os_reset_dhcp`)
9. OS별 마무리(`os_reid_finish`)
10. 적용 기록(`/etc/vmt/node.conf`)과 완료 기록(`os_reid_complete`)

`/etc/hosts`에 쓰는 IP는 첫 고정 주소 NIC의 첫 주소다. 고정 주소 NIC가 없으면 `127.0.1.1`을 쓴다.

### NIC 대응

노드 구성의 NIC 구역마다 이 VM의 물리 NIC(`/sys/class/net/<이름>/device`가 있는 NIC) 하나를 정한다.

1. `interface`에 이름이나 `mac:<MAC>`을 적은 구역을 먼저 정한다. 그 NIC는 템플릿의 NAT 인터페이스, 브리지나 본드의 포트(`master`가 있는 NIC)이면 안 된다. 기본 경로가 있으면 경고만 한다.
2. `interface = auto` 구역은 남은 물리 NIC 가운데 NAT 인터페이스도, 기본 경로를 가진 NIC도 아닌 후보가 하나일 때만 정한다. 후보가 없으면 어댑터를 붙였는지 확인하라고 안내하고, 기본 경로 때문에 뺀 NIC가 있으면 그 이름도 알려 준다. 둘 이상이면 후보와 MAC을 보여 주고 이름이나 MAC을 적으라고 한다.
3. 노드 구성에 없는 후보 NIC가 남으면 경고한다. 그 NIC의 설정은 만들지 않는다.

NIC에 이미 IPv4 주소가 있으면 경고한다. 호스트 전용 네트워크의 DHCP 서버가 켜져 있으면 Rocky의 NetworkManager가 임시 기본 유선 연결로 주소를 받아 둔다. NetworkManager는 연결 프로필이 없는 유선 NIC에만 이 임시 연결을 만들므로, vmt 프로필이 생긴 뒤 재부팅하면 노드 구성의 주소만 남는다([NetworkManager.conf의 no-auto-default](https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html)). 다른 OS에서 주소가 있으면 템플릿 설정이 그 NIC를 맡는지 확인한다.

### 경로와 DNS

기본 경로는 NAT에 둔다. 복제본은 NAT로 패키지를 받으므로, 노드 구성의 NIC가 기본 경로를 빼앗으면 외부 통신이 끊길 수 있다.

| NIC | 기본 경로 | 이유 |
| --- | --- | --- |
| `static`, `gateway` 없음 | 만들지 않는다 | 대역 안 통신과 `routes`의 경로만 쓴다 |
| `static`, `gateway` 있음 | 만든다. metric 50 | 사용자가 기본 경로를 옮기겠다고 적은 경우다. NAT 쪽 DHCP 기본 경로(netplan, NetworkManager의 유선 기본 metric 100, dhcpcd 기본 1000 + 인터페이스 번호)보다 앞선다 |
| `dhcp` | DHCP가 주면 받는다. metric 2000 | NAT 쪽 기본 경로보다 뒤에 둔다. NAT가 끊겼을 때만 쓰인다 |

| OS | 게이트웨이 | DHCP 경로 metric | 경로 | DNS |
| --- | --- | --- | --- | --- |
| Ubuntu | `routes`의 `to: default`, `metric: 50` | `dhcp4-overrides.route-metric` | `routes`의 `to`, `via` | `nameservers.addresses`, `search` |
| Rocky | `gateway=`, `route-metric=50`. 게이트웨이가 없으면 `never-default=true` | `route-metric=2000` | `routeN=대상,게이트웨이` | `dns=`, `dns-search=` |
| Debian | `gateway`, `metric 50` | `metric 2000`(dhcpcd의 `-m`, dhclient의 `IF_METRIC`로 넘어간다) | `up ip route add`, `down ip route del` | `dns-nameservers`, `dns-search`(resolvconf가 있어야 반영된다) |
| PVE | 쓰지 않는다 | `dhcp`를 쓰지 않는다 | 쓰지 않는다 | 적용하지 않는다(웹 UI의 DNS 설정을 쓴다) |

근거 문서는 [netplan YAML 설정](https://netplan.readthedocs.io/en/stable/netplan-yaml/), [nm-settings-keyfile(5)](https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html), [interfaces(5)](https://manpages.debian.org/trixie/ifupdown/interfaces.5.en.html), [ifupdown의 inet.defn](https://sources.debian.org/src/ifupdown/0.8.45/inet.defn), [dhcpcd(8)](https://man.cx/DHCPCD(8))다.

DNS 서버와 검색 도메인은 노드 단위 값이다. 첫 고정 주소 NIC에 붙이고, 고정 주소 NIC가 없으면 첫 DHCP NIC에 붙인다. NAT 쪽 DHCP가 주는 DNS는 그대로 남는다.

### 추가 디스크

`vmt-reid`는 빈 디스크만 나눈다. 데이터가 있는 디스크를 잘못 가리켜 지우는 사고를 막기 위해서다. 빈 디스크는 아래를 모두 만족하는 디스크다.

- `/sys/block/<디스크>`에 파티션 항목이 없다.
- `/sys/block/<디스크>/holders`가 비어 있다(LVM, RAID, 암호화가 쓰지 않는다).
- `blkid -p`가 서명(파티션 테이블, 파일 시스템)을 찾지 못한다(종료 코드 2).

같은 `device`의 볼륨은 파일 순서대로 나뉜다.

| `lvm` | 만드는 구조 | 크기 |
| --- | --- | --- |
| `no`(기본) | 볼륨마다 GPT 파티션 하나. 파티션 이름은 볼륨 이름이다 | `size`는 `sfdisk`의 `size=<MiB>MiB`로 넘긴다. 크기가 없는 마지막 볼륨은 남은 공간을 모두 쓴다 |
| `yes` | 디스크 전체를 GPT 파티션 하나(LVM 형식)로 만들고 PV, VG(기본 `vg_<디스크>`), 볼륨마다 LV를 만든다. LV 이름은 볼륨 이름이다 | `lvcreate -L <MiB>m`. 크기가 없는 마지막 LV는 `-l 100%FREE`다 |

파티션은 `sfdisk` 스크립트(`label: gpt`, `type=L` 또는 `type=V`, `name=`)로 만들고, 새 파티션 안에 남은 이전 서명은 `--wipe-partitions always`로 지운다([sfdisk(8)](https://man7.org/linux/man-pages/man8/sfdisk.8.html)). `mkfs`는 표준 입력을 닫고 실행한다. 확인 질문에서 멈추지 않고 실패로 끝나게 하기 위해서다.

`/etc/fstab`은 원본에서 다시 만들고 끝에 볼륨마다 `UUID=<UUID> <마운트 경로> <fs> <options> 0 <pass>` 줄을 붙인다. `pass`는 ext4가 2, xfs가 0이다. 기본 옵션 `defaults,nofail`은 디스크를 떼어 낸 복제본도 부팅되게 한다. 줄을 쓴 뒤 `systemctl daemon-reload`로 마운트 유닛을 다시 만들고 경로마다 `mount`를 실행한다. 마운트 경로가 비어 있지 않은 디렉터리면 안의 파일이 가려지므로 사전 검사에서 거부한다.

디스크마다 만든 결과를 `/var/lib/vmt/disk/<디스크>`에 기록한다. 다시 만들어야 바뀌는 값(볼륨 이름, 크기, 파일 시스템, LVM, VG, 레이블)과 UUID다. 다시 실행할 때 기록과 구성이 같으면 디스크를 다시 만들지 않고 기록의 UUID로 `/etc/fstab`만 다시 만든다. 다르면 거부한다. 파티션을 만든 뒤 기록 전에 멈춘 디스크는 빈 디스크가 아니므로 다시 실행하면 거부하고, `wipefs -a`로 비우라고 안내한다.

### 루트 디스크 확장

`root_grow = yes`인 노드는 호스트에서 늘린 디스크 공간을 루트 파일 시스템에 더한다. 루트 파일 시스템은 ext4나 xfs여야 한다.

1. `findmnt`로 루트 장치를 찾는다. LVM 논리 볼륨이면 그 VG의 PV를 찾는다. PV가 하나이고 파티션이면 그 파티션을, LVM이 아니면 루트 파티션을 늘릴 대상으로 정한다.
2. `growpart -N`으로 늘릴 수 있는지 미리 본다. 종료 코드 0은 늘릴 수 있음, 1은 늘릴 공간 없음, 2는 오류다([growpart(1)](https://manpages.ubuntu.com/manpages/noble/man1/growpart.1.html)). 오류면 아무것도 바꾸기 전에 멈춘다.
3. 적용할 때 `growpart`로 파티션을 디스크 끝까지 늘린다. LVM이면 `pvresize` 뒤 VG의 남은 공간 전체를 `lvextend -r -l +100%FREE`로 루트 LV에 더한다. LVM이 아니면 `resize2fs`(ext4)나 `xfs_growfs /`(xfs)로 파일 시스템을 늘린다.

LVM이면 디스크를 늘리지 않았어도 VG의 남은 공간을 루트 LV에 더한다. Ubuntu 설치 프로그램은 VG 일부만 루트 LV에 주기 때문이다. 루트 파티션 뒤에 다른 파티션(스왑 등)이 있으면 `growpart`가 늘릴 공간 없음으로 답하고 아무것도 늘리지 않는다. Proxmox VE는 남은 공간을 `pve/data`(씬 풀)에 쓰는 경우가 많아 `root_grow = no`를 권한다.

### 메뉴

메뉴는 번호와 글자를 입력받는 줄 단위 화면이다. 안내는 표준 출력에 쓰고 입력은 표준 입력에서 받으므로 입력을 파이프로 넘겨 테스트할 수 있다. 입력이 끝나면(Ctrl+D, 파이프 끝) 저장하지 않고 1로 끝난다.

- 값을 물을 때 `[ ]` 안에 지금 값을 보여 준다. 값이 비어 있으면 대신 쓰일 값(공통값, 기본값)을 괄호로 보여 준다. 엔터는 지금 값을 그대로 두고 `-`는 값을 지운다.
- 값은 입력할 때 `vmt_value_error`로 검사하고, 틀리면 이유를 보여 주고 다시 묻는다. 필수 값(고정 주소 NIC의 `address`, 디스크의 `device`와 `mount`)은 빈 값으로 넘어가지 못한다.
- NIC를 `dhcp`나 `off`로 바꾸면 쓸 수 없는 값(`address`, `gateway`, `routes`)을 지우고 알린다.
- NIC와 디스크를 고칠 때 이 VM의 NIC(MAC, 주소)와 디스크(크기, 파티션 유무)를 보여 준다.
- 키 사이의 조합 검사는 저장(`vmt-nodes`)과 계획(`vmt-reid`) 때 노드 전체로 한다.

### OS별 차이

| OS | NIC 설정 | SSH 호스트 키 | DHCP 클라이언트 식별 정보 |
| --- | --- | --- | --- |
| Ubuntu 26.04 | netplan 파일 `60-vmt.yaml` 하나. NIC 구역마다 항목 `vmt-<이름>`, MAC 일치(`match.macaddress`), 권한 600. `netplan generate`로 문법을 검사한다 | 바로 다시 만든다 | systemd-networkd가 machine-id에서 계산한다. machine-id 재생성으로 바뀐다 |
| Rocky 9, 10 | NIC 구역마다 keyfile `vmt-<이름>.nmconnection`, `mac-address` 고정, IPv6는 링크 로컬만(`off`는 끈다). 다시 실행하면 이전 vmt 프로필을 지우고 다시 만든다. `restorecon`으로 라벨을 맞추고 `nmcli connection reload`로 다시 읽힌다 | 지우기만 한다. 부팅 때 `sshd-keygen@.service`가 만든다 | v2 `secret_key`와 machine-id로 계산한다. 임대 기록을 지운다 |
| Debian 13 | `interfaces.d/vmt` 하나. NIC마다 `allow-hotplug`과 스탠자. 주소가 여럿이면 같은 인터페이스의 스탠자를 주소마다 둔다. ifupdown은 이름으로 NIC를 찾으므로 MAC은 주석으로 남긴다 | 바로 다시 만든다 | dhcpcd의 `duid`, `secret` 파일을 지운다. 다음 시작 때 새로 만든다 |
| Proxmox VE 9 | `/etc/network/interfaces` 끝에 NIC 구역마다 브리지 스탠자(`vmbr1`부터 빈 번호). `static`은 주소 있는 브리지, `off`는 주소 없는 브리지(VM용)다 | 바로 다시 만든다 | 브리지가 모두 정적 주소라 지울 상태가 없다 |

Rocky는 새 파일 시스템을 마운트한 뒤 `restorecon -R`로 마운트 경로의 라벨을 맞춘다(`os_after_mount`).

OS별 점검(`os_reid_checks`)은 템플릿 설정이 노드 구성의 NIC도 맡는 구성을 거부한다.

| OS | 거부하는 구성 | 이유 |
| --- | --- | --- |
| Ubuntu | 다른 netplan 파일에 그 NIC 이름의 장치 항목이나 그 이름과 맞는 `match.name`(glob 포함)이 있다 | systemd-networkd는 한 NIC에 맞는 `.network` 파일 가운데 이름순으로 처음 것만 쓴다([systemd.network(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html)). 템플릿 쪽 파일이 앞서면 vmt 설정이 무시된다 |
| Rocky | 다른 프로필의 `interface-name`이 그 NIC다 | 한 NIC에 두 프로필이 맞아 어느 프로필이 연결될지 정해지지 않는다 |
| Debian | 그 NIC의 `iface`, `auto`, `allow-*` 줄이 이미 있다 | 같은 인터페이스를 두 번 정의한다 |
| PVE | 그 NIC에 주소 설정이 있거나 다른 브리지의 포트다 | 브리지 포트로 쓸 수 없다 |

Ubuntu의 검사는 YAML을 해석하지 않고 줄 단위로 두 형태만 본다. 그 밖의 형태(MAC 일치, 드라이버 일치)로 같은 NIC를 맡는 설정은 잡지 못하고, NIC에 이미 주소가 있다는 경고로 드러난다.

PVE 노드 구성에는 추가 규칙이 있다(`os_cfg_validate_node`). `method`는 `static`이나 `off`만 쓰고, `gateway`와 `routes`를 쓰지 않고, NIC마다 주소를 하나만 둔다. 노드 IP가 될 `static` NIC가 하나 이상 있어야 한다.

### Proxmox VE 두 단계

Proxmox VE는 노드 이름이 클러스터 파일 시스템(`/etc/pve`)의 노드 디렉터리와 노드 인증서에 기록되어 있다. 실행 중인 시스템에서 이름만 바꾸면 이 둘이 따라오지 않으므로 재부팅을 사이에 둔다. PVE에는 sudo가 기본으로 없어 안내 문구는 root 셸 기준으로 쓴다.

| 단계 | 명령 | 내용 |
| --- | --- | --- |
| 1 | `vmt-reid`(메뉴, `--node`, 호스트명·IP 인자) | 호스트명, `/etc/hosts`, 브리지, 추가 디스크, 루트 확장, postfix 이름, machine-id, SSH 호스트 키를 바꾼다. 노드 IP(`/etc/hosts`의 노드 줄)는 NAT 주소에서 첫 고정 주소로 옮긴다. 실행 중인 호스트명은 바꾸지 않는다. 재부팅 때 새 이름으로 올라와야 새 노드 디렉터리가 생긴다 |
| 2 | `vmt-reid --finish` | 재부팅 확인(실행 중인 호스트명, `/etc/pve/local` 링크, 노드 IP 브리지의 새 IP) 뒤 옛 노드 디렉터리, 템플릿 root 키 쌍, known_hosts 항목(옛 이름, 옛 NAT 주소), 클러스터 CA, 티켓 서명 키(authkey), 노드 인증서를 지우고 `pvecm updatecerts --force`로 다시 만든다 |

브리지는 `/etc/network/interfaces` 자체에 둔다. PVE 웹 UI의 파서는 이 파일만 읽고 `interfaces.d`는 읽지 않는다([Proxmox 포럼, 직원 답변](https://forum.proxmox.com/threads/ui-not-showing-content-of-etc-network-interfaces-d.169312/)). 웹 UI에 보여야 VM 네트워크로 고를 수 있다. 스탠자 끝의 `#vmt-reid nic <이름>` 줄은 웹 UI에서 그 브리지의 설명(Comment)으로 보인다. `vmt-clean`은 이 줄로 남은 vmt 설정을 찾는다. 브리지 번호는 원본 설정 파일 기준으로 정하므로 계획과 적용, 다시 실행한 결과가 같다.

재부팅 때 `pveproxy`가 시작 전에 인증서를 갱신하므로 템플릿 CA로 서명한 새 노드 인증서가 먼저 생긴다. 2단계는 그 CA와 인증서를 지운 뒤 다시 발급한다([pvecm(1)](https://pve.proxmox.com/pve-docs/pvecm.1.html)). 새 인증서에 노드 IP가 들어가도록 노드 IP 브리지에 새 IP가 올라온 뒤에만 진행한다. `authorized_keys`에서는 템플릿 root 공개키 줄만 빼고, 템플릿에 미리 넣어 둔 사용자 키는 남긴다.

### OS별 훅

`src/lib/`이 흐름을 정하고 OS별 파일은 아래 함수와 변수만 정의한다. 뒤에 정의한 함수가 앞의 기본 정의를 덮어쓴다.

| 함수나 변수 | 역할 | 기본 동작 | 재정의 |
| --- | --- | --- | --- |
| `os_require` | OS와 버전 확인 | 없음(필수) | 전부 |
| `VMT_NET_CONF` | NIC 설정 파일 경로 | 없음(필수) | 전부 |
| `os_write_network` | NIC 설정 파일 작성. `P_NICS`, `P_IF`, `P_MAC`과 `pn` 함수로 값을 읽는다 | 없음(필수) | 전부 |
| `os_network_present` | 남은 vmt NIC 설정 찾기 | `VMT_NET_CONF`가 있는지 | Rocky(`vmt-*.nmconnection`), PVE(표시 줄) |
| `os_net_desc` | 계획과 결과에 보여 줄 설정 파일 설명 | `VMT_NET_CONF` | Rocky, PVE |
| `os_template_mac` | 템플릿 판별용 MAC | NAT 인터페이스의 MAC | PVE(브리지 포트의 MAC) |
| `os_clean_checks` | `vmt-clean` 사전 점검 | 없음 | Ubuntu, Rocky, Debian, PVE |
| `os_clean_extra` | `vmt-clean` OS별 정리 | 없음 | 전부 |
| `os_cfg_validate_node` | 노드 구성의 OS별 규칙 | 없음 | PVE |
| `os_reid_checks` | `vmt-reid` 사전 점검 | 없음 | 전부 |
| `os_after_net_edit` | 설정 반영과 검사 | 없음 | Ubuntu, Rocky |
| `os_after_mount` | 추가 디스크 마운트 뒤 처리 | 없음 | Rocky(SELinux 라벨) |
| `os_ssh_hostkeys` | SSH 호스트 키 | 지운 뒤 바로 생성 | Rocky |
| `os_reset_dhcp` | DHCP 클라이언트 상태 | 없음 | Rocky, Debian |
| `os_reid_finish` | 마지막 처리 | 없음 | Rocky(machine-id 라벨) |
| `os_reid_complete` | 기록과 결과 출력 | 완료 기록, 결과, 재부팅 안내 | PVE(2단계 기록, 완료 기록은 2단계가 남긴다) |
| `os_reid_stage2` | `--finish` 처리 | 사용법 오류 | PVE |
| `VMT_RENAME_RUNTIME` | 실행 중인 호스트명도 바로 바꿀지 | 1 | PVE(0) |
| `VMT_GROWPART_PKG` | `growpart`를 제공하는 패키지(안내용) | `cloud-guest-utils` | Rocky(`cloud-utils-growpart`) |

## 상태 파일

| 경로 | 만드는 명령 | 내용 | 수명 |
| --- | --- | --- | --- |
| `/etc/vmt/template.env` | `vmt-clean` | 형식 번호, 템플릿 호스트명, FQDN, NAT 인터페이스, NAT 주소, MAC, OS, 시각, 버전 | 복제본이 디스크와 함께 물려받는다 |
| `/etc/vmt/nodes.conf` | 사용자, `vmt-nodes` | 노드 목록 | 템플릿에 두고 복제본이 물려받는다. `install.sh`는 건드리지 않는다 |
| `/etc/vmt/nodes.conf.bak` | `vmt-nodes` | 메뉴로 저장하기 바로 전 파일 | 저장할 때마다 바뀐다 |
| `/etc/vmt/nodes.conf.example` | `install.sh` | 노드 목록 예시와 형식 설명 | 설치할 때마다 새로 쓴다 |
| `/etc/vmt/node.conf` | `vmt-reid` | 적용한 노드 구성(`[defaults]` 값을 합친 값)과 NIC 대응 주석 | 기록용이다. 다시 적용하지 않는다 |
| `/etc/vmt/reid.done` | `vmt-reid` | 실행 시각, 옛 이름과 새 이름, 노드 이름, 버전 | 있으면 `vmt-reid`와 `vmt-clean`이 거부한다 |
| `/var/lib/vmt/reid-backup/` | `vmt-reid` | 고치기 전 원본(`/etc/hosts`, `/etc/fstab` 등) | 처음 실행 때만 만든다. 재실행은 이 원본에서 다시 만든다 |
| `/var/lib/vmt/disk/<디스크>` | `vmt-reid` | 추가 디스크를 만든 구성과 볼륨별 UUID | 다시 실행할 때 구성과 대조한다 |
| `/var/lib/vmt/pve-stage1` | PVE `vmt-reid` 1단계 | 노드 이름, 옛 이름과 NAT 주소, 새 이름, FQDN, IP/접두, 노드 IP의 NIC와 브리지 | 2단계가 끝나면 지운다 |
| NIC 설정 파일 | `vmt-reid` | README의 네트워크 구성 표 | 복제본에 남는다. 템플릿에 있으면 `vmt-clean`이 거부한다 |

`template.env`의 형식 번호(`VMT_TPL_SCHEMA`)는 키 구성이 바뀔 때 올린다. `vmt-reid`는 번호가 다르면 거부하고 템플릿을 이 버전의 `vmt-clean`으로 다시 정리하라고 안내한다. 현재 번호는 2다. 1은 템플릿에 관리 IP를 두던 공개 전 설계의 형식이다.

복제본을 새 템플릿으로 쓰려면 `/etc/vmt/reid.done`, `/etc/vmt/node.conf`, vmt NIC 설정, `/etc/fstab`의 vmt 줄을 지운 뒤 `vmt-clean`을 실행한다.

## 템플릿 전제 조건

| 조건 | 이유 |
| --- | --- |
| NIC는 NAT 하나이고 기본 경로를 가진다 | 기본 경로로 NAT 인터페이스를 정한다. 복제본에서는 NAT가 아닌 NIC를 노드 구성의 NIC에 맞춘다 |
| Ubuntu, Rocky, Debian은 NAT 주소를 DHCP로 받는다 | 복제본마다 주소를 바꿀 필요가 없다 |
| PVE는 `vmbr0`에 VirtualBox NAT 주소를 정적으로 둔다 | PVE 설치 관리자가 정적 주소를 쓴다. VirtualBox NAT 어댑터 1은 늘 `10.0.2.0/24`다 |
| 템플릿의 NAT 설정이 MAC에 고정되어 있지 않다 | 복제본은 MAC이 바뀐다. Rocky는 `vmt-clean`이 MAC 고정 줄을 지우고, Ubuntu는 경고한다 |
| Debian은 `interfaces.d`를 읽는다 | NIC 설정이 그 디렉터리에 생긴다 |
| Rocky 9는 keyfile만 쓴다 | ifcfg의 `HWADDR` 고정은 지우지 않는다. `nmcli connection migrate`로 옮긴다 |
| PVE는 빈 단독 노드, `.link` 고정 없음 | 클러스터와 게스트 설정은 노드 이름에 묶여 있다. MAC으로 이름을 고정하면 복제본에서 브리지 포트를 잃는다 |
| 노드 목록에 오류가 없다 | 오류가 있는 목록을 템플릿에 굳히지 않는다 |
| 쓰는 기능의 패키지가 있다 | `root_grow`는 `growpart`(Ubuntu, Debian, PVE는 `cloud-guest-utils`, Rocky는 `cloud-utils-growpart`), `fs = xfs`는 `xfsprogs`, `lvm = yes`는 `lvm2`, Debian의 DNS는 `resolvconf`가 있어야 한다. 복제본은 템플릿의 패키지를 물려받는다 |

## 테스트 전략

테스트 대상은 `dist/`의 생성 파일이다. 사용자가 실행하는 파일을 그대로 시험한다.

`tests/run.sh`는 케이스 파일마다 [unshare(1)](https://man7.org/linux/man-pages/man1/unshare.1.html)로 마운트와 호스트명 네임스페이스를 새로 만들고 그 안에서 실행한다. 샌드박스 구성은 다음과 같다.

- `/etc`, `/var`, `/root`, `/home`, `/usr/local`, `/usr/lib/systemd`, `/srv`를 [overlayfs](https://docs.kernel.org/filesystems/overlayfs.html)로 덮는다. 쓰기는 tmpfs 위 상위 계층에만 남는다. 마운트 경로 테스트는 `/srv` 아래를 쓴다.
- `/run`은 tmpfs로 바꾸고, `/sys/class/net`과 `/sys/block`은 가짜 디렉터리로 바꾼다. 물리 NIC에는 `device` 항목을, 브리지 포트에는 `master` 항목을 둔다. 디스크에는 `size`(섹터 수)와 `ro`를, 파티션에는 하위 디렉터리를 둔다.
- 임시 파일(`mktemp`)은 샌드박스 안에 만든다.
- `ip`(주소 목록과 기본 경로), `systemctl`, `ssh-keygen`, `nmcli`, `netplan`, `restorecon`, `curl`, 패키지 관리자, 디스크 명령(`blkid`, `sfdisk`, `mkfs.*`, LVM 명령, `lsblk`, `findmnt`, `growpart`, `resize2fs`, `xfs_growfs`, `udevadm`, `mount`)은 `tests/stubs`의 대역이 받는다. 대역은 호출 인자를 기록하고 정해진 출력을 낸다. `curl` 대역은 URL의 `/dist/` 뒤 경로를 저장소의 `dist/`에서 찾아 돌려준다. `sfdisk` 대역은 받은 스크립트를 남기고 가짜 sysfs에 파티션을 만들며, `mkfs` 대역은 UUID를 정해 `blkid` 대역이 답하게 한다. `systemd-machine-id-setup`, `install`, `sha256sum`, `mountpoint`는 실제 명령을 쓴다. `mount`에 대역이 있으므로 하네스는 `command -p mount`로 실제 `mount`를 부른다.

스크립트가 이 목록 밖의 경로에 쓰게 되면 하네스의 `SB_OVERLAYS`에 경로를 더한다. 그러지 않으면 테스트가 실제 시스템을 바꾼다.

케이스 파일은 `setup` 함수와 `test_`로 시작하는 함수로 구성한다. 테스트마다 파일 트리를 새로 만든다. 공통 처리(`/etc/hosts`, NIC 대응, 입력 검사, 재실행)는 Ubuntu 케이스에서 주로 검사하고, OS 케이스마다 정상 경로, OS별 거부 경로, Hyper-V 구성(`eth0` NAT, `eth1` 내부 스위치), 여러 NIC의 설정 파일 형식을 둔다. 노드 구성 케이스(`nodes.sh`)는 파일 읽기와 검사, 여러 NIC, 추가 디스크, 루트 확장, 메뉴(입력을 파이프로 넘긴다), `vmt-nodes`, `vmt-clean` 연동을 검사한다. 설치 스크립트 케이스는 OS 판별, 내려받기 주소, 체크섬 불일치, 노드 목록 보존, `--clean`을 검사한다.

| 확인하는 항목 | 확인하지 못하는 항목 |
| --- | --- |
| 거부 조건과 거부 시 무변경 | 재부팅 뒤 systemd, NetworkManager, systemd-networkd, dhcpcd, ifupdown2의 실제 동작 |
| 설정 파일 내용과 권한 | `sshd-keygen@.service`의 실제 키 생성 |
| 호출한 명령과 인자(`sfdisk` 스크립트, `mkfs`, LVM, `growpart`) | SELinux 라벨의 실제 값 |
| 실패 뒤 재실행 결과 | `netplan generate`의 실제 문법 검사 |
| 메뉴 입력과 출력 | 실제 디스크의 파티션, 파일 시스템, 마운트, 루트 확장 |
| 인터페이스 이름이 다른 구성 | pmxcfs와 `pvecm updatecerts`, 웹 UI 인증서와 브리지 설명 |
| 체크섬 검사와 설치 | raw 주소의 실제 응답 |

하네스를 고친 뒤에는 일부러 틀린 단언이나 소스 변이(검사 한 줄 삭제 같은)를 넣어 실패가 잡히는지 확인한다. 모든 테스트가 처음부터 통과하면 하네스가 실패를 놓치고 있을 수 있다. 0.1.0 개발 중에는 검사 한 줄을 지우거나 조건을 뒤집는 변이 72개(노드 구성, 디스크, 루트 확장, 메뉴 포함)를 넣어 모두 실패로 잡히는 것을 확인했다.

## 검증 현황

| OS | 샌드박스 테스트 | VirtualBox 실제 VM | Hyper-V 실제 VM |
| --- | --- | --- | --- |
| Ubuntu 26.04 | 통과 | 진행 전 | 진행 전 |
| Rocky 9 | 통과 | 진행 전 | 진행 전 |
| Rocky 10 | 통과 | 진행 전 | 진행 전 |
| Debian 13 | 통과 | 진행 전 | 진행 전 |
| Proxmox VE 9 | 통과 | 진행 전 | 범위 밖 |

ShellCheck는 첫 CI 실행에서 처음 돌린다. 경고가 나오면 고친 뒤 첫 태그를 붙인다.

실제 VM 검증은 복제본 하나를 만들어 `vmt-reid`와 재부팅까지 한 뒤 아래를 확인한다. OS별 확인 명령은 하이퍼바이저 문서의 OS 페이지에 있다.

1. 호스트명과 `/etc/hosts`가 새 값이다.
2. 노드 구성의 NIC에 그 주소만 있고, NAT NIC는 DHCP 주소와 기본 경로를 받는다(`gateway`를 적은 노드는 그 게이트웨이가 기본 경로다). `dhcp` NIC의 기본 경로는 metric 2000이다.
3. machine-id가 템플릿과 다르다.
4. 호스트에서 관리 IP로 SSH 접속이 되고, 호스트 키 지문이 템플릿과 다르다.
5. NAT 쪽 DHCP 클라이언트 식별자가 템플릿과 다르다.
6. 템플릿과 복제본을 동시에 켜도 이름과 주소가 충돌하지 않는다.
7. 추가 디스크가 `/etc/fstab`의 UUID 줄로 마운트되어 있고(`findmnt`), 디스크를 떼고 부팅해도 멈추지 않는다(`nofail`).
8. 루트 확장을 쓴 노드는 루트 파일 시스템이 늘어나 있다(`df -h /`, LVM은 `lvs`).
9. Proxmox VE는 노드 IP로 웹 UI에 접속되고, `/etc/pve/nodes`에 새 이름만 있고, 노드 인증서의 이름과 IP가 새 값이며, 웹 UI 네트워크 목록에 브리지가 설명과 함께 보인다.

결과는 README와 이 문서의 표에 날짜와 함께 적고 CHANGELOG에 남긴다.

## 버전과 릴리스

`VERSION` 파일이 버전 번호의 유일한 원본이다. 빌드가 이 값을 생성 파일 머리, `--version` 출력, `install.sh`의 기본 태그에 넣고, `vmt-clean`은 `template.env`에 기록한다. 그래서 어느 버전으로 만든 템플릿인지 복제본에서 확인할 수 있다.

번호는 [SemVer(Semantic Versioning, 유의적 버전)](https://semver.org/lang/ko/)를 따른다. 이 저장소에서 공개 인터페이스는 명령 인자, 종료 코드, 노드 구성 파일 형식(구역, 키, 값), `template.env` 형식, NIC 설정 파일의 경로와 형식, `install.sh` 옵션, 템플릿 전제 조건이다.

| 변경 | 올리는 자리 | 예 |
| --- | --- | --- |
| 옛 템플릿이나 옛 사용법과 함께 쓸 수 없는 변경 | MAJOR | `template.env` 형식 번호 변경, 인자 순서 변경, 노드 구성 키의 이름이나 뜻 변경, 전제 조건 강화 |
| 하위 호환을 지키는 추가 | MINOR | OS 버전 디렉터리 추가, 새 옵션, 새 노드 구성 키 |
| 동작 수정 | PATCH | 버그 수정, 메시지 수정 |

`0.y.z` 동안은 SemVer 규칙대로 무엇이든 바뀔 수 있다. 이 기간에는 호환을 깨는 변경도 MINOR로 올리고 CHANGELOG에 `**Breaking:**`으로 표시한다. 지원 범위의 모든 디렉터리가 실제로 쓰는 하이퍼바이저에서 실제 VM 검증을 통과하면 `1.0.0`을 붙인다.

변경 기록은 [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/) 형식을 따른다. 항목 종류는 Added, Changed, Deprecated, Removed, Fixed, Security이고, 작업 중인 변경은 `[Unreleased]` 아래에 쌓는다.

릴리스 절차는 다음과 같다. `main`은 규칙 세트로 보호되므로 릴리스 커밋도 PR로 들어간다.

1. `chore/release-vX.Y.Z` 브랜치에서 CHANGELOG의 `[Unreleased]`를 `[X.Y.Z] - YYYY-MM-DD`로 바꾼다.
2. `VERSION`을 고친다.
3. `bash tools/build.sh`로 `dist/`를 다시 만든다. `install.sh`의 기본 태그가 `vX.Y.Z`로 바뀌고 `SHA256SUMS`가 갱신된다.
4. `sudo bash tests/run.sh`가 통과하는지 확인한다.
5. 제목이 `chore(release): vX.Y.Z`인 PR을 열고, CI가 통과하면 스쿼시 병합한다.
6. `main`을 받아 병합된 커밋에 `git tag -a vX.Y.Z -m "vX.Y.Z"`로 태그를 만들고 태그를 올린다.
7. `gh release create vX.Y.Z --draft --verify-tag --title vX.Y.Z --notes-file <노트 파일> dist/install.sh dist/SHA256SUMS`로 초안 릴리스를 만든다. 노트에는 CHANGELOG의 그 버전 항목을 옮긴다.
8. 첨부 파일을 확인하고 `gh release edit vX.Y.Z --draft=false`로 발행한다.

저장소 설정에서 불변 릴리스를 켜 두었으므로 발행하는 순간 태그와 첨부 파일이 잠긴다. 첨부는 초안 단계에서 끝낸다. 태그 이름은 `install.sh`의 기본 태그와 같아야 한다. 태그는 다시 만들지 않으며, 불변 릴리스의 태그 이름은 릴리스를 지운 뒤에도 다시 쓸 수 없다. 잘못 올린 버전은 다음 PATCH로 고친다.

## 브랜치와 커밋

`main`은 항상 CI를 통과한 상태로 둔다. 작업은 짧은 브랜치에서 하고 PR로 병합한다. 개인 저장소이므로 리뷰 승인은 요구하지 않고 CI 통과만 요구한다. 이 규칙은 규칙 세트로 강제한다(소유자 결정 사항).

커밋 메시지는 [Conventional Commits](https://www.conventionalcommits.org/ko/v1.0.0/) 형식으로 쓰고 설명은 한국어로 쓴다. PR은 스쿼시 병합하고 PR 제목이 `main`의 커밋 메시지가 되므로, 형식은 PR 제목에서 지킨다. 브랜치 이름은 `<타입>/<범위>-<요약>` 형식이다(예: `fix/rocky-10-ifcfg-warning`).

| 타입 | 쓰는 경우 |
| --- | --- |
| `feat` | 새 OS 버전, 새 옵션, 새 노드 구성 키, 새 정리 항목 |
| `fix` | 동작 수정 |
| `test` | 테스트만 바꾼 변경 |
| `docs` | 문서만 바꾼 변경 |
| `ci`, `build` | CI, 빌드 스크립트 |
| `refactor` | 동작이 같은 구조 변경 |
| `chore` | 릴리스, 설정 파일 |

범위는 `lib`(`src/lib/` 전체), `config`(노드 구성 파일), `menu`, `install`, `ubuntu-26.04`, `rocky`(Rocky 공유 정의), `rocky-9`, `rocky-10`, `debian-13`, `pve-9`, `tests`, `tools`를 쓴다. 호환을 깨는 변경은 PR 제목의 타입 뒤에 `!`를 붙이고, 병합할 때 스쿼시 커밋 본문에 `BREAKING CHANGE:`를 적는다. Dependabot이 여는 PR은 `ci:`로 시작하는 영어 제목을 그대로 쓴다.

`src/`를 바꾼 PR에는 다시 빌드한 `dist/`를 함께 넣는다. 둘이 다르면 CI에서 실패한다.

## CI

`.github/workflows/ci.yml`은 `main` 푸시와 PR에서 실행된다.

1. `bash tools/build.sh --check`: `dist/`와 `src/`의 일치
2. `shellcheck -S warning`: 생성 파일(`install.sh` 포함), 빌드 스크립트, 테스트 코드([ShellCheck](https://github.com/koalaman/shellcheck)). info와 style 수준은 이어 붙인 파일의 구조 때문에 생기는 지적이 많아 제외한다. 예를 들어 `vmt-clean`에는 `vmt-reid`에서만 쓰는 공통 함수도 포함되므로 "호출하지 않는 함수"(SC2329, info) 지적이 나온다
3. `sudo bash tests/run.sh`: 샌드박스 테스트

실행 환경은 `ubuntu-24.04`로 고정한다. 테스트가 실제 `systemd-machine-id-setup`과 overlayfs를 쓰므로 이미지가 바뀌면 결과가 달라질 수 있다. 실행 환경을 올릴 때는 PR 하나로 따로 올린다. 이 이미지에는 ShellCheck가 설치되어 있다([runner-images](https://github.com/actions/runner-images)).

워크플로의 액션은 전체 커밋 SHA로 고정하고 줄 끝에 버전 주석을 단다. 태그는 다른 커밋으로 옮길 수 있기 때문이다. 저장소 설정에서 SHA 고정을 강제하므로 태그로 참조한 액션은 실행되지 않는다([Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)). Dependabot(`.github/dependabot.yml`)이 매주 새 버전을 확인해 SHA와 버전 주석을 함께 바꾸는 PR을 연다. 새 버전이 나오고 7일이 지나야 PR을 연다. 워크플로 토큰 권한은 `contents: read`다.

## 줄 끝과 실행 권한

`.gitattributes`의 `* text=auto eol=lf`로 모든 텍스트 파일을 LF로 저장하고 LF로 꺼낸다([gitattributes](https://git-scm.com/docs/gitattributes)). CRLF가 섞인 스크립트는 bash가 `$'\r': command not found` 오류를 낸다. Windows의 `core.autocrlf` 설정과 관계없이 적용된다. `SHA256SUMS`도 LF 기준 내용으로 계산하므로 줄 끝이 바뀌면 설치 스크립트의 체크섬 검사가 실패한다.

Windows 파일 시스템은 실행 권한을 기록하지 않는다. 대역 명령은 PATH로 찾으므로 실행 권한이 없으면 테스트가 돌지 않는다. `tests/run.sh`는 권한이 빠진 대역을 찾으면 바로 멈춘다. 처음 커밋할 때 권한을 Git에 직접 기록한다([git add --chmod](https://git-scm.com/docs/git-add)).

```bash
git add --chmod=+x dist/install.sh dist/*/*/vmt-* tools/build.sh tests/run.sh tests/stubs/* tests/stubs-pve/*
```

이미 커밋한 파일은 `git update-index --chmod=+x <파일>`로 고친다. `git ls-files -s tests/stubs`에서 모드가 `100755`인지 확인한다.

## 새 OS 버전 추가 절차

1. 실제 VM에 설치하고 하이퍼바이저 문서의 절차로 템플릿을 만든다.
2. 이전 버전과 달라진 점을 확인한다. 네트워크 설정 형식, SSH 호스트 키 생성 방식, DHCP 클라이언트, 설치 기록 파일이 대상이다.
3. `src/os/<os>/<버전>/`에 `_shared.sh`(`os_require`, `VMT_NET_CONF`), `clean.sh`, `reid.sh`(`os_write_network`, `os_reid_checks`), `nodes.sh`(`vmt_nodes_main "$@"`)를 만든다. 이전 버전과 같은 처리는 `_family.sh`로 옮긴다. 노드 구성에 OS별 제약이 있으면 `os_cfg_validate_node`를 정의한다.
4. `tests/cases/<os>-<버전>.sh`에 정상 경로, 거부 경로, Hyper-V 구성, 여러 NIC의 설정 파일 형식을 쓴다.
5. `bash tools/build.sh`와 `sudo bash tests/run.sh`를 실행한다. `install.sh`의 지원 대상 목록은 빌드가 디렉터리에서 채운다.
6. README 지원 범위 표와 네트워크 구성 표, CHANGELOG Added, 하이퍼바이저 문서의 OS 페이지를 갱신한다.
7. MINOR를 올려 릴리스한다.
8. 실제 VM 검증을 마치면 검증 현황 표를 갱신한다.

## OS 버전 은퇴 절차

1. 그 버전의 템플릿과 복제본을 더 쓰지 않는지 확인한다.
2. `src/os/<os>/<버전>/`과 케이스 파일을 지운다. `_family.sh`를 쓰는 버전이 하나만 남으면 그 버전 디렉터리로 합친다.
3. 빌드하고 테스트한다.
4. README 표에서 지우고 CHANGELOG Removed에 적는다.
5. `0.y.z` 동안은 MINOR, `1.0.0` 이후에는 MAJOR를 올린다. 옛 태그에는 그 버전이 남는다.

## 설계 결정

| 결정 | 채택 | 대안 | 근거 |
| --- | --- | --- | --- |
| 템플릿 네트워크 | NAT NIC 하나(DHCP), 관리 IP 없음 | 템플릿에 관리 IP를 두고 복제본에서 바꾼다(공개 전 설계) | 템플릿이 관리망 주소 하나를 차지하지 않는다. 설정 파일 안에서 IP를 찾아 바꾸는 처리와 그 전제 조건(IP/접두 표기, 그 표기가 있는 파일이 하나)이 없어진다. 템플릿을 켜도 복제본과 관리 IP가 겹치지 않는다 |
| NIC 설정 방식 | 노드 구성의 NIC 설정 파일을 새로 만든다 | 템플릿 설정 파일 안의 값을 바꾼다 | 템플릿 설정 형식(게이트웨이 표기, `netmask` 줄)과 관계없다. 바뀐 내용이 vmt 파일로 모인다. 템플릿의 NAT 동작이 그대로 남는다 |
| 노드 구성 위치 | 템플릿의 노드 목록 하나 | 노드마다 파일을 따로 두고 복제본에 복사한다, 호스트에서 시드 ISO로 넣는다 | 복제본에 따로 넣을 파일이 없다. 노드 목록은 `vmt-clean`이 검사한 뒤 템플릿 디스크와 함께 복제된다. 목록에 없는 노드는 복제본의 메뉴에서 만든다 |
| 노드 구성 형식 | INI | YAML, 셸 변수 파일 | bash와 awk만으로 읽고 줄 번호로 오류를 알린다. YAML은 들여쓰기 규칙이 있고 bash로 읽으려면 파서(yq)가 따로 필요하다. 셸 변수 파일은 `source`로 읽으면 파일 안의 명령이 실행된다 |
| 입력 방식 | 파일과 번호 메뉴를 함께 둔다. 메뉴는 같은 파일을 만들고 고친다 | 파일만, 질문과 답만 | 파일은 여러 노드를 한 번에 적고 다시 쓰기 좋다. 메뉴는 형식을 몰라도 값을 넣을 수 있고 입력 즉시 값을 검사한다. 둘이 같은 검사 함수를 쓴다 |
| 메뉴 구현 | `printf`와 `read`의 줄 단위 메뉴 | dialog, whiptail | 추가 패키지가 없고, 직렬 콘솔과 SSH에서 같게 동작하고, 입력을 파이프로 넘겨 테스트할 수 있다. pfSense, OPNsense 콘솔 메뉴와 같은 방식이다 |
| 기본 경로 | NAT에 둔다. `gateway`를 적은 NIC만 앞서고(metric 50), DHCP NIC는 뒤에 둔다(metric 2000) | 노드 구성의 NIC에 기본 경로를 준다 | 복제본은 NAT로 패키지를 받는다. 기본 경로를 옮기는 일은 사용자가 `gateway`로 분명히 적을 때만 한다 |
| 추가 디스크 대상 | 빈 디스크만 나눈다 | 기존 파티션 테이블을 지우고 다시 나눈다 | 장치 이름(`sdb`)이 바뀌거나 잘못 적었을 때 데이터를 지우지 않는다. 다시 쓰려면 사용자가 `wipefs -a`로 직접 비운다. `disk_size`로 크기도 대조할 수 있다 |
| 추가 디스크 마운트 | `/etc/fstab`의 UUID 줄, `defaults,nofail` | systemd 마운트 유닛 파일, 장치 이름 줄 | UUID는 장치 이름이 바뀌어도 같다. `nofail`은 디스크를 떼어 낸 복제본도 부팅되게 한다. fstab 줄은 사람이 읽고 고치기 쉽다 |
| 루트 확장 도구 | `growpart`와 파일 시스템 도구, LVM이면 `lvextend -r` | `parted resizepart`, `sfdisk -N` | `growpart`는 늘릴 공간이 없을 때 종료 코드 1로 알려 주고, 미리 보기(`-N`)가 있어 바꾸기 전에 판단할 수 있다 |
| NIC를 찾는 기준 | netplan과 NetworkManager는 MAC, ifupdown과 PVE는 이름 | 모두 이름 | 두 도구는 MAC 일치를 지원해 Hyper-V에서 이름이 바뀌어도 같은 NIC에 붙는다. ifupdown은 이름으로만 찾는다. VirtualBox 이름은 PCI 슬롯에서 정해지고, Hyper-V는 NIC를 재부팅마다 같은 순서로 제공한다([Microsoft, systemd-devel 2020-01](https://lists.freedesktop.org/archives/systemd-devel/2020-January/043910.html)) |
| Hyper-V 관리망 | 내부 스위치 `LabNet`(NAT 없음)과 Default Switch | 내부 스위치 하나와 `New-NetNat`(공개 전 설계) | NAT를 Default Switch가 맡으므로 NetNat 구성이 필요 없다. Default Switch는 DHCP를 주므로 템플릿이 다른 하이퍼바이저와 같은 원칙(NAT NIC 하나, DHCP)을 따른다. Default Switch 대역은 바뀔 수 있어 관리망으로 쓰지 않는다. Default Switch가 `192.168.57.0/24`와 겹치는 대역을 고르면 `vmt-reid`의 NAT 대역 검사가 거부한다 |
| 새 IP 중복 확인 위치 | 호스트에서 관리망 쪽으로 확인 | 게스트에서 ping | 관리망 NIC에 주소가 없을 때 게스트의 ping은 NAT 기본 경로로 나가 관리망의 사용 여부를 알 수 없다 |
| PVE 브리지 위치 | `/etc/network/interfaces`에 `vmbr1`부터 | `interfaces.d`의 파일 | PVE 웹 UI는 `/etc/network/interfaces`만 읽는다. 웹 UI에 보여야 VM 네트워크로 고를 수 있다 |
| 스크립트 배포 | `install.sh`가 태그 경로에서 받아 `SHA256SUMS`로 검사 | `scp` 복사, `git clone` | 템플릿에 git이 필요 없고 OS 판별을 사람이 하지 않는다. 태그 고정으로 같은 템플릿을 다시 만들 때 같은 파일을 받는다 |
| `template.env` 형식 번호 | 번호를 기록하고 다르면 거부 | 키가 있는지만 검사 | 공개 전 형식에도 같은 이름의 키가 있어 키 검사만으로는 형식 차이를 구분하지 못한다 |
| 식별 정보를 새로 만드는 위치 | 복제본에서 `vmt-reid` 실행 | 템플릿에서 식별 정보를 미리 지워 두고 복제본 첫 부팅에 맡긴다(virt-sysprep, Windows Sysprep의 일반화 단계에 해당) | 호스트명과 IP는 어느 쪽이든 복제본마다 입력해야 한다. 미리 지우는 방식은 템플릿을 다시 켤 때마다 다시 지워야 하고, 템플릿이 정상 노드로 남지 않는다 |
| 템플릿 VM 판별 | MAC 비교 | 템플릿에 표식 파일 | 표식 파일은 디스크와 함께 복제되어 템플릿과 복제본을 구분하지 못한다. MAC은 복제 기능이 새로 만든다 |
| 재실행 안전성 | 원본 보관 뒤 원본에서 다시 생성 | 제자리 치환 | 제자리 치환은 실패 지점에 따라 두 번째 실행 결과가 달라진다 |
| cloud-init과 시드 ISO | 보류 | 복제본마다 시드 ISO로 이름과 주소 주입 | 복제본마다 ISO를 만들고 붙이는 호스트 작업이 늘어난다. 복제본 수가 늘면 다시 검토한다 |
| IPv6 고정 주소 | 범위 밖 | IPv6 표기 처리 추가 | 현재 실습망이 IPv4 고정 주소만 쓴다 |
| 저장소 이름 | `vm-template-kit` | `vm-templates`, `vmt` | `vm-templates`는 템플릿 이미지를 모은 저장소로 읽힌다. `kit`으로 스크립트 도구 모음임을 드러낸다. 명령 접두사 `vmt`는 VM template의 약자로 남겨 명령어, 경로, 함수 이름을 바꾸지 않는다. `vmt`만 쓰면 이름으로 용도를 알 수 없고, 검색 결과가 Source 엔진의 머티리얼 파일 확장자(`.vmt`)와 섞인다 |
| 명령 이름 | `vmt-clean`, `vmt-reid`, `vmt-nodes` | OS별 이름(`deb-reid`, `pve-reid`) | OS가 늘어도 사용법이 같다. 어느 OS용인지는 설치한 파일의 머리 주석과 `--version`으로 확인한다 |
| 라이선스 | MIT | Apache-2.0, GPL-3.0 | 저작권 고지와 허가 고지의 유지만 요구해 스크립트 한 파일을 복사해 쓰는 사용 방식과 맞는다. 셸 스크립트에서 Apache-2.0의 특허 조항은 실익이 적다. GPL-3.0은 수정본 배포에 같은 라이선스를 요구해 다른 사람이 업무에 쓰기 어렵다 |
| 병합 방식 | 스쿼시 병합, 커밋 메시지는 PR 제목 | 병합 커밋, 리베이스 병합 | PR 하나가 `main`의 커밋 하나가 되어 기록이 선형으로 남는다. Conventional Commits 형식은 PR 제목 한 곳에서 지키면 된다 |
| 액션 고정 방식 | 전체 커밋 SHA 고정, SHA 고정 강제 설정, Dependabot 갱신 | 워크플로 락파일(`.github/workflows/actions.lock`) | 쓰는 액션이 `actions/checkout` 하나이고 이 액션은 안에서 다른 액션을 부르지 않아, 락파일이 SHA 고정보다 더 막는 것이 없다. 락파일 강제 정책은 아직 미리 보기다. 제3자 액션이나 composite 액션을 들일 때 다시 검토한다 |

## 소유자 결정 사항

저장소를 만들 때 정한 값이다. GitHub 설정은 이 표에 맞춘다. 규칙 세트는 `.github/rulesets/`의 JSON 파일을 Settings → Rules → Rulesets의 Import a ruleset으로 가져와 만든다. GitHub에서 규칙 세트를 고치면 내보낸 JSON으로 이 파일을 갱신한다.

| 항목 | 값 | 영향 |
| --- | --- | --- |
| 저장소 이름 | `2davi/vm-template-kit` | `tools/build.sh`의 `RAW_BASE`, README의 설치 명령 |
| 공개 여부 | 공개 | 비공개면 `install.sh`가 raw 주소에서 받지 못한다. `--base-url`로 다른 위치를 주거나 `dist/` 파일을 복사한다. 무료 플랜의 규칙 세트도 공개 저장소에서만 동작한다 |
| 라이선스 | MIT, 저작권자 `2davi` | `LICENSE`, 생성 파일 머리의 고지 |
| `main` 보호 | 규칙 세트 `main-branch`: 삭제와 강제 푸시 금지, 선형 기록, PR 필수(승인 0, 스쿼시만), `test` 검사 필수(GitHub Actions에서 온 결과만, 최신화 필수), 우회 없음 | 브랜치와 커밋 |
| 태그 보호 | 규칙 세트 `release-tags`: `v*` 태그의 이동과 삭제 금지. 규칙 세트 `block-v-branches`: `v*` 브랜치 생성 금지 | 버전과 릴리스, 설치 스크립트 |
| 병합 | Allow squash merging만 켜고 기본 메시지는 Pull request title. 병합한 브랜치 자동 삭제 | 브랜치와 커밋 |
| 릴리스 | Enable release immutability | 버전과 릴리스, 설치 스크립트 |
| Actions | GitHub이 만든 액션만 허용, 전체 커밋 SHA 고정 강제, 외부 기여자의 워크플로 실행은 승인 필수, 워크플로 토큰은 읽기 전용, 워크플로의 PR 생성과 승인 금지 | CI |
| 보안 기능 | 비공개 취약점 신고, Dependabot 알림, 비밀 검사와 푸시 보호, CodeQL 기본 설정(SHA 고정 강제와 부딪치면 고급 설정으로 바꾼다) | `SECURITY.md` |
