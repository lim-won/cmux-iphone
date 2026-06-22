<h1 align="center"><strong>Cmux iPhone</strong></h1>

<p align="center">
  <a href="README.md">English</a> · <strong>한국어</strong>
</p>

<p align="center">
  <a href="https://github.com/lim-won/cmux-iphone/actions/workflows/ci.yml"><img src="https://github.com/lim-won/cmux-iphone/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License: MIT"/>
  <img src="https://img.shields.io/github/v/release/lim-won/cmux-iphone" alt="Release"/>
</p>

<p align="center">
  아이폰(과 Apple Watch)에서 <strong>Claude Code</strong>, <strong>Codex</strong>, <strong>cmux</strong>
  세션을 보고 제어하세요.<br/>
  실시간 터미널 출력 확인과 프롬프트 전송, 권한 요청은 아이폰에서 승인(Apple Watch에서는 모니터링) — LAN 또는 Tailscale로.
</p>

https://github.com/user-attachments/assets/5f478c28-2086-4696-9d76-e43dda853201

---

## 동작 방식 (두 부분)

```
   iPhone / Watch  ──HTTP+SSE──►  cmux-iphone bridge (Node)  ──hooks──►  Claude Code
   (SwiftUI app)   ◄────────────  on your Mac                 ──RPC───►  cmux mirror
                                                              ──log───►  Codex
```

- **브리지(Mac):** Claude Code 훅 이벤트를 받고, 실시간 cmux 워크스페이스를 미러링하고,
  Codex를 감시하며, HTTP + Server-Sent Events로 폰에 제공하는 작은 Node 서버(`cmux-iphone`).
  Bonjour로 LAN에서 자동 발견됩니다.
- **앱(iPhone + Watch):** 브리지와 페어링해 실시간 세션/터미널 출력을 보여주고 권한
  프롬프트에 응답하는 SwiftUI 앱.

모든 것이 **당신의 기기 안에서만** 동작합니다 — 클라우드도, 계정도, 호스팅할 서버도 없습니다.
브리지는 LAN에 바인딩되며, 페어링 코드 + 기기별 토큰이 인증 경계입니다.
**Tailscale 또는 신뢰할 수 있는 LAN에서 사용하세요 — 공개 인터넷에 노출하도록 만들어지지 않았습니다**
([`SECURITY.md`](SECURITY.md) 참고).

> **cmux는 선택입니다.** cmux가 설치돼 있으면 실시간 워크스페이스/터미널 미러를 얻고,
> 없어도 브리지는 훅 기반 Claude/Codex 세션을 계속 스트리밍합니다.

---

## 요구 사항

| 구성 요소 | 최소 |
|-----------|---------|
| macOS | 13+ |
| Node.js | 18+ |
| Xcode | 16+ (앱 빌드용) |
| iOS / watchOS | 17 / 10 |
| Claude Code | 최신 |
| cmux | 선택, **0.63.2+** (cmux의 `mobile.*` RPC 사용) |
| Tailscale | 선택 (원격 접속) |

---

## 설치 — Mac 브리지

### Homebrew (권장)

```bash
brew install lim-won/tap/cmux-iphone
cmux-iphone setup
```

`brew upgrade cmux-iphone`으로 업데이트하고, 이후 `cmux-iphone setup`을 한 번 다시 실행해
LaunchAgent / cmux 워크스페이스가 새 버전 경로를 가리키도록 하세요.

### 소스에서

```bash
git clone https://github.com/lim-won/cmux-iphone && cd cmux-iphone/skill/bridge
npm ci                        # reproducible install (use `npm install` if no lockfile)
npm link                      # optional: puts `cmux-iphone` on your PATH
cmux-iphone setup             # or: node bin/cmux-iphone.js setup
```

`cmux-iphone setup`은 **멱등적**입니다(여러 번 실행해도 안전). 다음을 수행합니다:

1. macOS + Node 18+ 확인, Claude/Codex/cmux/Tailscale 감지,
2. `config.json` 작성 및 시크릿 생성(`0600`, 재실행 시 회전되지 않음),
3. `~/.claude/settings.json`을 **백업**한 뒤 Cmux iPhone 훅을 병합(범위 한정 —
   다른 도구의 훅은 절대 건드리지 않음),
4. 러너 선택 — cmux가 있으면 **in-cmux**(실시간 미러 동작), 없으면 **LaunchAgent**,
5. 브리지 헬스 체크 후 LAN/Tailscale 주소 + 페어링 코드 출력.

> **왜 러너가 둘인가요?** `launchd` 프로세스는 cmux 컨트롤 소켓에 도달할 수 없습니다(검증됨).
> 그래서 cmux가 있으면 브리지를 cmux 워크스페이스 *안에서* 실행하고, 없으면 훅/폰/Codex
> 세션만 제공하는 LaunchAgent로 실행합니다.

### cmux 미러 사용

실시간 cmux 미러를 쓰려면, setup을 실행할 때 **cmux가 실행 중이고 컨트롤 소켓에 도달 가능**해야
합니다(소켓 비밀번호를 쓰면 미리 설정). 그런 다음:

```bash
cmux-iphone setup --cmux     # fails fast if cmux RPC isn't reachable (instead of half-installing)
cmux-iphone doctor           # confirm:  cmux RPC = mobile.workspace.list OK
```

cmux는 설치돼 있지만 소켓에 도달할 수 없으면, setup이 중단되고 알려줍니다 — 미러링할 수 없는
브리지를 조용히 띄우지 않습니다. cmux를 완전히 건너뛰고 훅/폰/Codex 세션만 쓰려면:
`cmux-iphone setup --launchd`.

CLI로 관리합니다:

| 명령 | 설명 |
|---|---|
| `cmux-iphone setup` | 설치 / 복구 (멱등적) |
| `cmux-iphone doctor` | 읽기 전용 진단 — **GitHub 이슈에 붙여넣기 좋음** |
| `cmux-iphone status` | 브리지 상태, LAN/Tailscale 주소, cmux, 페어링된 기기 |
| `cmux-iphone pair` | 페어링 코드 표시 · `--list` · `--revoke <id>` |
| `cmux-iphone logs` | LaunchAgent 로그 tail (in-cmux 브리지는 **Agent Bridge** 워크스페이스에서 확인) |
| `cmux-iphone restart` | 브리지 재시작 |
| `cmux-iphone uninstall` | 훅 + 서비스 제거 (`--purge`는 데이터까지 삭제) |

---

## 설치 — iPhone / Watch 앱 (직접 빌드)

**App Store / TestFlight 빌드는 없습니다** — Cmux iPhone은 소스로 배포되며, 본인의 무료
Apple ID로 빌드합니다. (TestFlight은 유료 Apple Developer Program이 필요하며, 프로젝트가
등록되면 공개 바이너리가 나올 수도 있습니다.)

**1. 번들 ID 설정** (한 줄 — XcodeGen 불필요; 아이폰 ID, 워치 ID, 워치 컴패니언 ID가 모두
여기서 파생됩니다):

```bash
./scripts/configure-ios.sh com.yourname.cmuxiphone
open ios/CmuxiPhone/CmuxiPhone.xcodeproj
```

**2. Xcode에 Apple ID 추가:** Xcode → Settings → Accounts → **+** → Apple ID
(무료 계정이면 충분).

**3. 두 타깃 모두 Team 설정:** 프로젝트 선택 → **CmuxiPhone**과 **CmuxiPhoneWatch**에 대해
Signing & Capabilities → *Automatically manage signing* → **Team = 본인 Personal Team**.
(번들 ID는 1단계에서 이미 설정됨.)

**4. 아이폰 개발자 모드 활성화 (iOS 16+):** Settings → Privacy & Security →
**Developer Mode** → On → 재시작. (워치에도 배포한다면 워치에서 동일하게: Watch 앱 /
watchOS Settings → Privacy & Security.)

**5. 실행:** 아이폰(워치 페어링 상태)을 연결하고 **CmuxiPhone** 스킴 + 아이폰을 대상으로 선택
→ **Run**(⌘R). 워치 앱은 **CmuxiPhoneWatch** 스킴과 페어링된 워치 대상을 선택(워치 직접 설치가
실패하면 아이폰을 통해 배포).

**6. 개발자 인증서 신뢰:** 아이폰에서 Settings → General → VPN & Device Management →
개발자 프로필 탭 → **Trust**.

> **무료 팀 제한:** 빌드 후 약 **7일**이 지나면 앱이 만료됩니다(Xcode에서 다시 실행해 갱신),
> **푸시 알림 없음**(로컬 알림만), 최대 3대. SideStore/AltStore로 *아이폰* 앱을 무선 자동
> 갱신할 수 있습니다.
>
> 메인테이너: 프로젝트는 `project.yml`에서 `xcodegen`으로 생성됩니다 — 프로젝트 구조를 바꿀
> 때만 필요하며, 일반 사용자는 위 스크립트를 씁니다.

### 페어링

1. 앱을 열고 → **페어링 코드**(아래 참고)와 **Mac의 IP 주소 또는 Tailscale 주소**를 입력
   (`cmux-iphone status`가 LAN과 Tailscale 주소를 보여줍니다).
2. 같은 Wi-Fi면 → 브리지가 자동 발견(Bonjour)되므로 주소 입력을 생략할 수 있습니다.
   네트워크가 다르면 **Tailscale 주소**를 써서 사무실이든 외부든 같은 페어링이 동작하게 하세요.

각 기기는 **자체 토큰**을 받습니다. `cmux-iphone pair --revoke <id>`로 폐기하세요
(`cmux-iphone pair --list` 참고).

#### 페어링 코드는 어디서 얻나요?

개발자가 아니어도 됩니다 — 길어야 두 개의 명령입니다:

- **설치 시,** `cmux-iphone setup`이 끝에 코드(와 주소)를 출력합니다. **Mac마다 하나의 안정적인
  코드**를 생성해 저장하므로 — 계속 바뀌지 않아 재사용할 수 있습니다.
- **나중에 언제든,** `cmux-iphone pair`를 실행하면 다시 보여줍니다.

```text
$ cmux-iphone pair
Pairing code: 000000
Enter this code in the Cmux iPhone app on your iPhone.
```

> **직접 코드 지정 (선택):** 브리지 환경에 `CMUX_IPHONE_PAIR_CODE=123456`을 설정해 기억하기
> 쉬운 코드를 고정할 수 있습니다. 코드는 페어링 관문입니다(레이트 리밋 — 5분당 5회, 각 기기는
> 여전히 자체 토큰을 받음). 비공개로 유지하세요. 신뢰할 수 있는 LAN 또는 Tailscale 사용을
> 권장하며, 브리지를 공개 인터넷에 직접 노출하지 마세요.

> **회전 코드 (선택):** 고정 코드 대신 회전하는 코드를 원하면 `cmux-iphone setup --rotating`을
> 실행하세요 — 재시작마다 새 6자리 코드(24h TTL, 기기 페어링 후 비워짐).

> **워치 승인 (베타):** 워치는 승인을 *보여주지만*, 현재는 아이폰에서 응답합니다.

---

## Tailscale 원격 접속

브리지는 평문 HTTP로 통신하며 LAN 또는 비공개 [Tailscale](https://tailscale.com) 테일넷을 위해
설계되었습니다 — **공개 인터넷용이 아닙니다**. Tailscale을 쓰면 같은 Wi-Fi에 있는 것처럼 어디서나
아이폰에서 Mac에 접속할 수 있습니다.

**1. 두 기기에 Tailscale 설치 + 같은 계정 로그인.**

```bash
brew install --cask tailscale     # Mac (또는 앱 다운로드) 후 로그인
```

아이폰에는 App Store에서 **Tailscale**을 설치하고 **같은** 계정으로 로그인하세요. 이제 두 기기가
하나의 비공개 테일넷을 공유합니다.

**2. Mac의 Tailscale 주소 확인.**

```bash
cmux-iphone status
# Tailscale: http://100.x.y.z:7860
```

`100.x.y.z`가 Mac의 테일넷 IP입니다. **MagicDNS**(Tailscale 관리 콘솔)를 켜면 호스트네임도 쓸
수 있습니다(예: `your-mac`).

**3. 그 주소로 폰을 페어링.** Bonjour 자동 발견은 같은 Wi-Fi에서만 동작하고 **테일넷을 넘지
못하므로**, 원격에서는 주소를 직접 입력해야 합니다: 앱에서 **Enter IP manually**를 탭하고
`100.x.y.z`(또는 MagicDNS 호스트네임)와 페어링 코드(`cmux-iphone pair`)를 입력하세요. 한 번
페어링하면 Wi-Fi·셀룰러 등 테일넷이 닿는 어디서나 동작합니다 — 재페어링 불필요.

**4. (권장) Tailscale 전용 바인딩.** 기본적으로 브리지는 LAN을 포함한 모든 인터페이스(`0.0.0.0`)에서
수신합니다. **Tailscale로만** 연결을 받으려면 테일넷 IP로 리스너를 고정하세요:

```bash
HOST=100.x.y.z cmux-iphone restart     # 또는 config.json의 "bindAddress" 설정
```

loopback 전용은 `127.0.0.1`. `cmux-iphone status`로 바인딩 주소를 확인하고, 원격 사용 시 Mac이
잠들지 않게 하세요: `sudo pmset -a sleep 0 && sudo pmset -a disablesleep 1`.

> **여러 Mac을 이동 중 쓰려면** [`REMOTE-SETUP.md`](REMOTE-SETUP.md)에서 각 Mac 이름 지정
> (`office-mac-1`, …)과 앱에서 전환하는 방법을 참고하세요.

---

## 문제 해결

먼저 **`cmux-iphone doctor`**를 실행하세요 — 시크릿 없는 PASS/WARN/FAIL 리포트를 출력하며
이슈에 붙여넣기 좋습니다.

- **아이폰 "Connection failed":** `cmux-iphone status`로 브리지의 **실제 주소 + 포트**를
  확인한 뒤(7860–7869 중 다른 포트이거나 loopback이 아닌 인터페이스일 수 있음) 거기로
  `/health`를 조회하세요 — 예: `curl http://<주소>:<포트>/health`(참고: `/status`는 인증 필요).
  브리지와 폰은 같은 LAN(또는 Tailscale)을 공유해야 합니다.
- **cmux 워크스페이스가 없음:** cmux는 브리지가 cmux *안에서* 실행될 때만 미러링합니다
  (`cmux-iphone status`가 러너를 표시). cmux가 없어도 훅 세션은 계속 동작합니다.
- **워치/폰이 브리지를 못 찾음(Bonjour):** 순서대로 점검하세요 — 앱의 iOS **로컬 네트워크**
  권한, 두 기기가 **같은 네트워크**인지, 공유기의 **AP/클라이언트 격리(isolation)** 해제,
  **mDNS 차단** 여부, 그래도 안 되면 **IP 직접 입력**(`cmux-iphone status`).
- **권한 프롬프트가 안 뜸:** `~/.claude/settings.json`의 훅과 기기가 페어링됐는지 확인
  (`cmux-iphone pair --list`).

---

## 동작 원리

### 이벤트 흐름 (Mac → 폰)
Claude Code가 툴을 실행 → `PostToolUse`/`PreToolUse` 훅이 브리지로 POST → 브리지가 SSE
이벤트를 push → 앱이 렌더링.

### 권한 흐름 (Mac → 폰 → Mac)
Claude가 권한 프롬프트에 도달 → `PermissionRequest` 훅이 **블록** → 브리지가
`permission-request` SSE 이벤트를 push → 폰이 옵션을 표시 → 선택이 다시 POST →
브리지가 결정을 Claude에 반환.
(codex exec 승인의 경우, 브리지가 *고정된* cmux 터미널에 답을 입력하며, 화면 해시로
보호됩니다 — 화면이 바뀌면 거부합니다.)

설치되는 훅(루프백 리스너, 시크릿 게이트): `PostToolUse`, `PreToolUse`,
`PermissionRequest`(블로킹, 최대 10분), `SessionStart`, `SessionEnd`, `Stop`, 오류 이벤트.

---

## 보안

브리지는 **기본적으로** `0.0.0.0:<port>`(LAN 도달 가능)에서 수신합니다. `bindAddress`(또는 `HOST`
환경 변수)로 Tailscale/loopback 인터페이스로 제한할 수 있습니다. 인증은 페어링 코드 + 기기별
토큰이며, 훅 리스너는 루프백 전용에 시크릿 게이트가 걸립니다. 시크릿은 저장소 밖에 `0600`으로
보관됩니다. 신뢰할 수 있는 LAN 또는 Tailscale 사용을 권장하며, 브리지를 공개 인터넷에 직접
노출하지 마세요. 전체 모델 + 신고 방법은 [`SECURITY.md`](SECURITY.md)에 있습니다.

## 라이선스

MIT — [`LICENSE`](LICENSE) 참고.

Cmux iPhone은 [shobhit99/claude-watch](https://github.com/shobhit99/claude-watch)(MIT)의
포크이며 원저작자 저작권을 보존합니다. 앱은 **중립 아이콘**을 사용합니다 — Claude/Anthropic이나
OpenAI/Codex 로고 에셋은 포함되지 않으며, "Claude"와 "Codex"는 각각 Anthropic과 OpenAI의
상표로 텍스트 라벨로만 쓰입니다. 본 프로젝트는 Anthropic이나 OpenAI와 무관한 독립 커뮤니티
도구입니다. 전체 출처는 [`NOTICE.md`](NOTICE.md) 참고.
