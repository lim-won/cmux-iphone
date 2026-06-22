# Cmux iPhone — 이동용 원격 설정 (여러 Mac + cmux + Tailscale)

> **English:** This is the advanced **multi-Mac** remote guide — naming several Macs
> (`office-mac-1`, …) and switching between them in the app. For the basic single-Mac
> Tailscale setup, see **Remote access over Tailscale** in the
> [README](README.md#remote-access-over-tailscale). The detailed steps below are in Korean.

목표: 아이폰에서 여러 office Mac의 cmux 안 claude/codex 세션을 **구분해서 보고,
승인하고, 프롬프트를 직접 입력**.

> 기본 설치는 [`README.md`](README.md) 참고. 이 문서는 **Tailscale로 여러 Mac을
> 원격**으로 쓰는 추가 설정만 다룹니다.

## 한 번만: 네트워크 (Tailscale)

1. iPhone + 각 Mac에 Tailscale 설치, 같은 계정 로그인.
2. 관리콘솔에서 Mac 이름을 구분되게: `office-mac-1`, `office-mac-2`.
3. (Bonjour는 tailnet을 못 넘으므로) 앱에선 **"Enter IP manually"**에
   `office-mac-1`(또는 100.x IP) 입력.

## 각 Mac에서

```bash
cd cmux-iphone/skill/bridge
npm ci && npm link            # cmux-iphone 를 PATH에
cmux-iphone setup             # 훅 등록 + runner 선택 + 기동 + 코드 출력
sudo pmset -a sleep 0 && sudo pmset -a disablesleep 1   # 잠들면 도달 불가
```

- **runner 자동 선택:** cmux가 있으면 브리지를 **cmux 워크스페이스 안에서** 실행
  (라이브 미러가 동작하려면 이래야 함 — launchd로는 cmux 소켓을 못 건드림).
  cmux가 없으면 **LaunchAgent**(훅/폰/Codex 세션만).
- **재부팅 생존:** **자동 로그인 ON.** cmux runner는 cmux 세션복원이, LaunchAgent
  runner는 로그인 세션이 브리지를 되살림.
- **페어링 코드:** `cmux-iphone pair` (고정 per-machine 코드 — Mac마다 한 번
  생성·저장되고 재부팅/재시작에도 유지, 회전하지 않음. pairing은 5분당 5회로
  rate-limit 보호). 회전 코드(24h TTL)는 opt-in입니다. 상태/주소는
  `cmux-iphone status`, 진단은 `cmux-iphone doctor`.
- **토큰은 영속** → 브리지 재시작/재부팅에도 페어링 유지. 재페어링 불필요.

## 아이폰 앱

- Xcode로 빌드(본인 Team/bundle id — README 참고) → 첫 페어링:
  "Enter IP manually"에 `office-mac-1` + 코드.
- **다른 Mac 추가:** 설정(⚙) → **Macs → Add another Mac** → `office-mac-2` + 코드.
- **전환:** 설정 → Macs에서 탭. (재페어링 없음 — 기기별 토큰 저장됨)
- **삭제:** Macs에서 스와이프. (또는 Mac에서 `cmux-iphone pair --revoke <id>`)

## 구분 방식

| 구분 | 어떻게 |
|---|---|
| 맥북 | 설정 → Macs 에서 선택한 연결 (체크 표시) |
| workspace | cmux 워크스페이스(폴더)별 |
| 세션 | `claude` / `codex` 배지 |

## 프롬프트 직접 입력 (cmux 미러)

세션을 고른 뒤 프롬프트를 보내면 bridge가 그 cmux 터미널에 **그대로 타이핑**합니다.

- **codex 승인은 fail-closed:** 그 명령을 *화면에 띄운* 터미널을 마커("Yes,
  proceed"/"No")로 특정하고, **화면 해시가 일치할 때만** `y`/`2`/Esc를 주입합니다.
  특정 불가/화면 변경 시 거부(카드 유지) — 엉뚱한 터미널에 입력하지 않습니다.

## 주의 (개인용)

- 아이폰 FaceID/암호 ON (분실 시 승인권한 보호). 분실 기기는
  `cmux-iphone pair --revoke <id>`로 폐기.
- 실자격(gcloud 등)이 있는 Mac에선 이동 중 `delete`/`destroy`/`push -f` 승인을
  한 번 더 확인.
- 공개 인터넷에 포트를 노출하지 말고 Tailscale/신뢰 LAN에서만 — [`SECURITY.md`](SECURITY.md).
