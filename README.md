# vm-template-kit

[![ci](https://github.com/2davi/vm-template-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/2davi/vm-template-kit/actions/workflows/ci.yml)

리눅스 VM 템플릿을 만들고 그 템플릿에서 링크된 복제본(linked clone)을 만들 때 게스트 안에서 실행하는 스크립트 모음이다. 명령 이름 앞의 `vmt`는 VM template의 약자다.

복제본은 템플릿의 호스트명, machine-id, SSH 호스트 키, NIC 설정을 그대로 물려받는다. 이 저장소는 복제본마다 이 값을 새로 만드는 작업을 명령 세 개로 고정한다. 템플릿에는 NAT NIC 하나만 두고 관리 IP를 두지 않는다. 복제본마다 달라지는 값(호스트명, NIC와 주소, 추가 디스크, 루트 디스크 확장)은 템플릿의 노드 목록(`/etc/vmt/nodes.conf`)에 적거나 복제본의 메뉴에서 입력한다.

| 명령 | 실행 위치 | 동작 |
| --- | --- | --- |
| `install.sh` | 템플릿 VM, 처음 한 번 | OS와 버전을 판별해 그 OS용 세 명령과 노드 목록 예시를 내려받고, `SHA256SUMS`로 검사한 뒤 설치한다 |
| `vmt-nodes` | 템플릿 VM | 노드 목록을 메뉴로 만들고 고친다. 손으로 고친 파일을 검사한다 |
| `vmt-clean` | 템플릿 VM, 스냅샷이나 부모 디스크를 만들기 직전 | 템플릿 조건과 노드 목록을 검사하고, NAT 인터페이스와 MAC을 기록하고, 복제본에 넘기면 안 되는 상태(random-seed, credential.secret, 설치 기록, 셸 기록, DHCP 임대 기록)를 지운다 |
| `vmt-reid` | 복제본, 첫 부팅 뒤 한 번 | 노드 하나를 골라 호스트명, `/etc/hosts`, NIC 설정, 추가 디스크, 루트 디스크 확장을 적용하고 machine-id, SSH 호스트 키, DHCP 클라이언트 식별 정보를 새로 만든다 |

| OS | 하이퍼바이저 |
| --- | --- |
| Ubuntu Server 26.04 LTS | VirtualBox, Hyper-V |
| Rocky Linux 9, 10 | VirtualBox, Hyper-V |
| Debian 13 (trixie) | VirtualBox, Hyper-V |
| Proxmox VE 9 (9.2 기준) | VirtualBox |

하이퍼바이저 쪽 작업(VM 생성, 스냅샷, 부모 디스크, 복제, 어댑터와 디스크 추가)은 스크립트로 두지 않는다. 그 절차는 [docs.the2davi.dev의 하이퍼바이저 문서](https://docs.the2davi.dev/notes/linux/hypervisor/)에 명령 단위로 있다.

## 검증 현황

0.1.0 기준이다. 실제 VM 검증은 아직 하지 않았다. 사용자가 실행하는 생성 파일(`dist/`)을 샌드박스에서 실행하는 테스트 114개가 통과하고, 이 테스트가 결함을 잡아내는지는 변이 72개로 확인했다. CI는 `main` 푸시와 PR마다 빌드 일치 검사, ShellCheck, 샌드박스 테스트를 다시 실행한다.

| OS | 샌드박스 테스트 | 실제 VM(VirtualBox) | 실제 VM(Hyper-V) |
| --- | --- | --- | --- |
| Ubuntu Server 26.04 LTS | 31개 통과 | 진행 전 | 진행 전 |
| Rocky Linux 9 | 13개 통과 | 진행 전 | 진행 전 |
| Rocky Linux 10 | 4개 통과 | 진행 전 | 진행 전 |
| Debian 13 | 10개 통과 | 진행 전 | 진행 전 |
| Proxmox VE 9 | 16개 통과 | 진행 전 | 범위 밖 |

OS에 묶이지 않는 테스트는 노드 구성, 추가 디스크, 루트 확장, 메뉴 30개와 설치 10개다. 실제 VM 검증은 복제본 하나를 만들어 `vmt-reid`와 재부팅까지 한 뒤 9개 항목을 확인하고, 결과를 이 표에 날짜와 함께 적는다. 항목은 [docs/DESIGN.md](docs/DESIGN.md)의 검증 현황에 있다.

### 샌드박스 테스트로 확인한 동작

테스트는 케이스 파일마다 마운트 네임스페이스를 새로 만들고, 시스템 디렉터리를 overlayfs로 덮고, `/sys/class/net`과 `/sys/block`을 가짜 디렉터리로 바꾼 뒤 실행한다. 네트워크와 디스크 명령은 호출 인자를 기록하는 대역 명령이 받고, `systemd-machine-id-setup`, `install`, `sha256sum`은 실제 명령을 쓴다. 거부하는 경우에는 파일을 하나도 바꾸지 않았는지까지 확인한다.

| 영역 | 확인한 동작 |
| --- | --- |
| 설치 | OS와 버전을 판별한다(Rocky 마이너 버전, Proxmox VE 포함). 지원하지 않는 OS와 체크섬 불일치는 거부하고 아무것도 설치하지 않는다. 노드 목록을 건드리지 않는다. 내려받기 실패와 `--ref`, `--base-url`, `--clean`을 처리한다 |
| 템플릿 정리 | NAT 인터페이스와 MAC을 기록한다. 기본 경로가 없거나 둘인 경우, 이전 관리망 설정이 남은 경우, OS 버전이 다른 경우, 복제본에서 실행한 경우를 거부한다. 노드 목록을 검사한다 |
| 노드 구성 파일 | 예시 파일이 검사를 통과한다. 형식, 값, 키 조합 오류를 줄 번호와 함께 모두 출력한다. 따옴표, 주석, CRLF 줄 끝을 처리하고 `[defaults]` 값을 합친다 |
| NIC 대응 | 이름, `mac:<MAC>`, `auto`로 NIC를 찾고, 후보가 둘 이상이면 거부한다. 여러 NIC, 주소 없는 NIC(`method = off`), Hyper-V 구성(`eth0` NAT, `eth1` 내부 스위치)을 설정한다 |
| 복제본 적용 | 호스트명과 `/etc/hosts`를 바꾸고 machine-id와 SSH 호스트 키를 새로 만든다. 템플릿 VM에서 실행하거나 두 번 실행하면 거부한다. 실패한 뒤 다시 실행하면 원본에서 설정을 다시 만든다. `--check`는 아무것도 바꾸지 않는다 |
| 추가 디스크 | GPT 파티션과 LVM을 만든다. 빈 디스크가 아니거나, 장치가 없거나, 크기가 맞지 않거나, 마운트 경로가 비어 있지 않으면 아무것도 바꾸지 않고 거부한다. 다시 실행하면 만든 결과를 재사용하고, `mkfs`가 실패하면 멈춘다 |
| 루트 확장 | 파티션(ext4, xfs)과 LVM 루트를 늘린다. VG의 남은 공간만 있는 경우와 늘릴 공간이 없는 경우를 처리한다 |
| 메뉴 | 노드 선택과 적용, 계획 수정 뒤 적용, 저장하지 않은 종료, 입력 끝(EOF)을 처리한다. 잘못된 값의 저장을 거부하고, 저장할 때 백업을 남긴다 |
| Proxmox VE | 재부팅을 사이에 둔 두 단계 실행과 빈 브리지 번호 선택을 확인한다. 재부팅 전의 `--finish`, 게스트가 있는 노드, 인터페이스 이름 고정, PVE 8을 거부한다 |

### 변이 테스트

테스트가 통과한다는 사실만으로는 테스트가 결함을 잡는다고 말할 수 없다. 그래서 0.1.0 개발 중에 소스에 변이 72개를 넣는 변이 테스트(mutation testing)를 했다. 변이는 검사 한 줄을 지우거나 조건을 뒤집는 방식이며, 노드 구성, 디스크, 루트 확장, 메뉴를 포함한다. 72개 모두 테스트 실패로 잡혔다.

### 샌드박스로 확인하지 못한 동작

아래 동작은 실제 VM에서만 확인할 수 있다.

- 재부팅 뒤 systemd, NetworkManager, systemd-networkd, dhcpcd, ifupdown2의 실제 동작과 `netplan generate`의 실제 문법 검사
- 실제 디스크의 파티션, 파일 시스템, 마운트, 루트 확장
- `sshd-keygen@.service`의 실제 키 생성과 SELinux 라벨 값
- Proxmox VE의 pmxcfs, `pvecm updatecerts`, 웹 UI 인증서와 브리지 설명
- raw 주소의 실제 응답

### 검증 재현

리눅스와 root 권한이 필요하다. 테스트는 샌드박스 안에서만 쓰므로 실제 시스템 파일은 바뀌지 않는다.

```bash
bash tools/build.sh --check    # dist/가 src/와 일치하는지 확인
sudo bash tests/run.sh         # 전체 테스트
sudo bash tests/run.sh nodes   # 케이스 파일 이름 접두로 골라 실행
```

## 사용 방법

템플릿 VM 준비부터 복제본 적용까지 아래 순서대로 진행한다. 하이퍼바이저 쪽 명령은 하이퍼바이저 문서의 OS별 글에 있다.

명령은 모두 전체 경로(`/usr/local/sbin/...`)로 실행한다. Rocky Linux의 sudo는 `/usr/local/sbin`을 검색 경로(`secure_path`)에 넣지 않기 때문이다. Proxmox VE에는 sudo가 기본으로 없으므로 root 셸에서 `sudo` 없이 실행한다.

### 1. 템플릿 VM 준비

OS를 설치하고 아래 조건을 맞춘다. `vmt-clean`이 이 조건을 검사하며, 거부할 때는 아무것도 바꾸지 않고 멈춘다.

- 어댑터는 NAT 하나만 붙이고, 그 NIC가 기본 경로를 가진다. VirtualBox는 NAT, Hyper-V는 Default Switch다. 다른 어댑터는 복제본을 만들 때 붙인다.
- Ubuntu, Rocky, Debian은 NAT 주소를 DHCP로 받는다. Proxmox VE는 `vmbr0`에 VirtualBox NAT 주소(`10.0.2.15/24`, 게이트웨이 `10.0.2.2`)를 정적으로 둔다.
- NAT 설정을 MAC 주소에 고정하지 않는다. 복제본은 MAC이 바뀐다. Rocky에서는 `vmt-clean`이 고정 줄을 지우고, Ubuntu에서는 경고한다.
- Debian은 `/etc/network/interfaces`에 `source /etc/network/interfaces.d/*` 줄이 있어야 한다.
- Rocky Linux 9는 ifcfg 형식 프로필 없이 keyfile만 쓴다. ifcfg 프로필은 `nmcli connection migrate`로 옮긴다.
- Proxmox VE는 클러스터에 가입하지 않고, VM과 CT를 만들지 않고, 인터페이스 이름 고정(`.link`)을 두지 않는다.

### 2. 설치

설치 스크립트와 체크섬 목록을 받아 설치 스크립트부터 검사한 뒤 실행한다. 설치 스크립트는 같은 태그의 세 명령과 노드 목록 예시를 받아 `SHA256SUMS`로 검사하고, 하나라도 다르면 아무것도 설치하지 않는다. 명령은 `/usr/local/sbin`에, 예시 파일은 `/etc/vmt/nodes.conf.example`에 놓인다. 노드 목록(`/etc/vmt/nodes.conf`)은 건드리지 않는다.

실행하기 전에 확인한다.

- Debian 기본 설치에 curl이 없으면 `sudo apt install curl`로 먼저 설치한다.
- raw 주소에 접근할 수 없으면 아래 명령 대신 PC에서 `dist/<os>/<버전>/`의 세 파일을 템플릿으로 복사하고 `sudo install -m 755 vmt-* /usr/local/sbin/`으로 설치한다.
- 노드 목록과 4단계의 패키지가 필요 없으면 마지막 줄을 `sudo bash install.sh --clean --poweroff`로 바꾼다. 설치 뒤 바로 `vmt-clean`을 실행하고 전원을 끄므로 3단계부터 5단계까지 건너뛴다.

```bash
base=https://raw.githubusercontent.com/2davi/vm-template-kit/v0.1.0/dist
curl -fsSLO "$base/install.sh"
curl -fsSLO "$base/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
sudo bash install.sh
```

`--ref`는 다른 태그나 브랜치를, `--base-url`은 다른 저장소 주소를 지정한다.

릴리스는 불변 릴리스(immutable release)로 발행하므로, 발행한 태그 경로의 파일은 바뀌지 않는다.

### 3. 노드 목록 작성

노드 목록 없이 진행하려면 이 단계를 건너뛴다. 그때는 복제본의 메뉴에서 노드 구성을 입력하거나, 호스트명과 IP를 인자로 준다(7단계).

노드 목록은 INI 형식이다. `[node]` 아래에 그 노드의 `[nic]`과 `[disk]`를 차례로 적는다. NAT NIC(첫 번째 어댑터)는 템플릿 설정을 그대로 쓰므로 적지 않는다. 형식과 키 설명은 [src/nodes.conf.example](src/nodes.conf.example)에 있다.

```ini
[defaults]
domain = lab.internal

[node web-01]

[nic mgmt]
interface = auto
address   = 192.168.56.11/24

[disk data]
device = sdb
fs     = xfs
mount  = /srv/data
```

- `[nic]`: `interface`는 `auto`(후보가 하나일 때), 인터페이스 이름, `mac:<MAC>` 가운데 하나다. `method`는 `static`, `dhcp`, `off`다. 주소 여럿, 게이트웨이, 경로, MTU를 적을 수 있다. 기본 경로는 NAT에 남는다. `gateway`를 적은 NIC만 NAT보다 앞서고(metric 50), `dhcp` NIC가 받는 기본 경로는 NAT보다 뒤(metric 2000)에 둔다.
- `[disk]`: 빈 디스크만 쓴다. 같은 `device`의 볼륨은 차례로 GPT 파티션이 되고, `lvm = yes`면 디스크 전체가 PV 하나가 되고 볼륨마다 LV가 생긴다. 파일 시스템 UUID로 `/etc/fstab` 줄(`defaults,nofail`)을 만들고 마운트한다.
- `root_grow = yes`: 호스트에서 늘린 만큼 루트 파티션과 파일 시스템을 늘린다. LVM이면 VG의 남은 공간도 루트 LV에 더한다.

메뉴로 만들거나, 예시 파일을 `/etc/vmt/nodes.conf`로 복사해 고친 뒤 검사한다. 메뉴에서는 번호나 글자로 고르고, 값을 물을 때 엔터는 지금 값을 그대로 두며 `-`는 값을 지운다.

```bash
sudo /usr/local/sbin/vmt-nodes            # 메뉴로 만들기
sudo /usr/local/sbin/vmt-nodes --check    # 손으로 고친 파일 검사
```

### 4. 패키지 설치

추가 디스크나 루트 확장을 쓰면 그 기능의 패키지를 템플릿에 설치한다. 복제본은 템플릿의 패키지를 물려받고, `vmt-reid`는 필요한 명령이 없으면 아무것도 바꾸기 전에 멈춘다.

| 쓰는 기능 | 명령 | Ubuntu, Debian, Proxmox VE | Rocky |
| --- | --- | --- | --- |
| `root_grow = yes` | `growpart` | `cloud-guest-utils` | `cloud-utils-growpart` |
| `fs = xfs` | `mkfs.xfs` | `xfsprogs` | 기본 설치 |
| `lvm = yes` | `pvcreate` 등 | `lvm2` | 기본 설치 |
| Debian의 `dns`, `search` | `resolvconf` | `resolvconf` | 필요 없음 |

### 5. 템플릿 정리

스냅샷이나 부모 디스크를 만들기 직전에 실행한다. 템플릿을 고친 뒤 스냅샷을 다시 만들 때도 직전에 다시 실행한다. 노드 목록이 있으면 함께 검사한다.

```bash
sudo /usr/local/sbin/vmt-clean --poweroff
```

### 6. 복제와 하드웨어 추가

전원이 꺼지면 호스트에서 스냅샷(VirtualBox)이나 부모 디스크(Hyper-V)를 만들고 링크된 복제본을 만든다. 첫 번째 어댑터는 NAT 그대로 두고, 노드 구성에 맞게 어댑터와 디스크를 붙인다. 루트 확장을 쓰는 노드는 복제본의 디스크를 늘린다.

| 하이퍼바이저 | 첫 번째 어댑터 | 두 번째 어댑터(문서의 기본 구성) |
| --- | --- | --- |
| VirtualBox | NAT | 호스트 전용 어댑터(`192.168.56.0/24`) |
| Hyper-V | Default Switch | 내부 스위치 `LabNet`(`192.168.57.0/24`, NAT 없음) |

복제본을 켜기 전에 새 IP를 다른 VM이 쓰고 있지 않은지 호스트에서 확인한다. 복제본 안에서는 관리망 NIC에 아직 주소가 없어서 확인할 수 없다.

### 7. 복제본 적용

복제본을 켜고 콘솔로 로그인해 실행한다. 실행하기 전에 확인한다.

- 템플릿 VM에서 실행하면 거부한다. 템플릿의 MAC 주소가 보이면 템플릿 VM으로 판단한다.
- 한 복제본에서는 한 번만 끝까지 실행한다. 중간에 멈췄다면 다시 실행해도 된다. 원본에서 설정을 다시 만들고, 이미 만든 디스크는 기록과 구성이 같으면 다시 만들지 않는다.
- 복제본의 메뉴에서 고친 노드 구성은 노드 목록에 쓰지 않고 적용 기록(`/etc/vmt/node.conf`)에만 남는다.
- Proxmox VE는 이 절의 마지막에 있는 두 단계 절차를 따른다.

노드 이름으로 바로 적용하거나, 인자 없이 실행해 메뉴에서 고른다. 메뉴는 적용 계획을 보여 준 뒤 적용한다.

```bash
sudo /usr/local/sbin/vmt-reid --check --node web-01   # 바꾸지 않고 계획만 출력
sudo /usr/local/sbin/vmt-reid --node web-01           # 적용
sudo reboot
```

노드 목록 없이 NIC 하나만 고정 주소로 설정할 때는 호스트명과 IP를 인자로 준다. 짧은 호스트명만 주면 템플릿 FQDN의 도메인을 붙인다. NIC 후보가 둘 이상이면 `--iface`로 지정한다.

```bash
sudo /usr/local/sbin/vmt-reid node-01.lab.internal 192.168.56.11/24
sudo reboot
```

Proxmox VE는 노드 이름이 `/etc/pve`의 노드 디렉터리와 노드 인증서에 기록되어 있어, 재부팅을 사이에 두고 두 단계로 실행한다. root 셸에서 실행한다.

```bash
vmt-reid --node pve-01
reboot
# 재부팅 뒤
vmt-reid --finish
```

### 8. 결과 확인

재부팅 뒤 아래를 확인한다. OS별 확인 명령은 하이퍼바이저 문서의 OS별 글에 있다.

- 호스트명과 `/etc/hosts`가 새 값이다.
- 노드 구성의 NIC에 그 주소가 있고, NAT NIC는 DHCP 주소와 기본 경로를 받는다. `gateway`를 적은 노드는 그 게이트웨이가 기본 경로다.
- machine-id와 SSH 호스트 키 지문이 템플릿과 다르다.
- 추가 디스크가 `/etc/fstab`의 UUID 줄로 마운트되어 있다. 루트 확장을 쓴 노드는 루트 파일 시스템이 늘어나 있다.

NIC 설정은 OS마다 아래 파일에 있다. 템플릿의 NAT 설정 파일은 고치지 않는다.

| OS | NIC 설정 파일 | NIC를 찾는 기준 |
| --- | --- | --- |
| Ubuntu 26.04 | `/etc/netplan/60-vmt.yaml`(NIC마다 항목 `vmt-<이름>`) | MAC(`match.macaddress`) |
| Rocky 9, 10 | `/etc/NetworkManager/system-connections/vmt-<이름>.nmconnection` | MAC(`ethernet.mac-address`) |
| Debian 13 | `/etc/network/interfaces.d/vmt` | 인터페이스 이름 |
| Proxmox VE 9 | `/etc/network/interfaces` 끝에 더한 브리지(`vmbr1`부터) | 인터페이스 이름(브리지 포트) |

## 관련 문서

- [docs/DESIGN.md](docs/DESIGN.md): 설계 결정, 명령 계약, 테스트 전략, 버전과 릴리스, 브랜치와 커밋 규칙
- [하이퍼바이저 문서](https://docs.the2davi.dev/notes/linux/hypervisor/): VM 생성부터 복제까지 호스트 쪽 명령과 OS별 확인 명령
- [CHANGELOG.md](CHANGELOG.md): 변경 기록
- [SECURITY.md](SECURITY.md): 지원 버전과 취약점 신고
- [LICENSE](LICENSE): MIT. 따로 복사해 쓰는 생성 파일(`dist/`)도 머리 주석에 같은 고지를 담는다
