# Architecture

## Plugback

> **문서 관계**
> - [FUNCTIONAL_SPEC.md](./FUNCTIONAL_SPEC.md) — 이 설계가 만족시켜야 할 동작. 이 문서의 상위.
> - [CONTEXT.md](../CONTEXT.md) — 용어. 이 문서의 모든 용어는 여기를 따른다.
>
> 이 문서는 모듈 경계와 인터페이스만 정한다. 모듈 내부 구현은 구현자의 재량이다.

---

## 1. 설계 원칙

스펙의 복잡성은 다섯 군데에 몰려 있다. 각각을 깊은 모듈 하나에 가두고, 나머지는 얇게 유지한다.

1. **연결 이벤트의 노이즈** — 디바운스, 위상 게이트, 잠자기 억제, 잠금 미루기 → DisplayWatcher
2. **접근성 API의 함정** — 좌표계 2개, 조용한 실패, 응답 없는 앱, 앱 실행·창 열기의 비동기 등장 → WindowGateway
3. **저장 정책** — 작업 환경 단위 저장본, 창별 기록·병합, 저장 대기 이력과 확정, 창 연결과 닫힌 환경 → WorkspaceLibrary / CaptureEngine
4. **복원 정책** — Space 조건, 창 대응, 다시 열기 허용, 건너뜀 사유 → RestoreEngine / WindowMatching
5. **복원 요청의 시간축** — 소스 고정, 방문·이동·확인·잠금 대기, 취소 규칙, 실행 직전 게이트 → RestoreSession

## 2. 모듈 맵

```
DisplayWatcher ──이벤트──▶ PlugbackController ◀──조작── MenuBarUI · 복원 확인 창 · 설정 · App Intent
CollectTrigger ──이벤트──▶      │
ActiveSpaceWatcher ──────▶      ├─▶ WorkspaceLibrary ─▶ CaptureEngine · WindowMatching(재대응) · ProfileStore
MissionControlWatcher ───▶      │
                               ├─▶ RestoreSession ─▶ RestoreEngine ─▶ WindowMatching
                               │         │
                               ├─────────┴─▶ DesktopObservation
                               │                ├─▶ WindowGateway (+ WindowMoveSource)
                               │                └─▶ SpaceReader
                               ├─▶ SpacesSupport · ScreenLock · DiagnosticsLog
Space snapshot ─▶ SpacePlacement ─▶ CaptureEngine · RestoreEngine · PlugbackController
PlugbackController ─▶ ScreenProvider (ScreenID · PortLocator 내장)
```

CaptureEngine과 RestoreEngine은 게이트웨이를 모른다 — 이미 열거된 창·Space 관찰을 받는 거의 순수 함수다.
저장·수집·카드 갱신과 모든 복원 실행의 창 열거는 같은 DesktopObservation을 통한다.

### DisplayWatcher

- **인터페이스**: 콜백 넷 — `onExternalScreensAppeared()` / `onExternalScreensRemoved(식별자들)` / `onRawChange()` (원시 변경 신호 — 수집을 멈추기 위해) / `onScreenUnlocked()` (잠금 보류 재개용). 제거를 등장보다 먼저 보고한다.
- **숨기는 것**: 이벤트 안정화 대기(F-01.2), 위상 게이트·잠자기 억제·잠금 미루기(F-01.3). 미뤄둔 등장은 화면 식별자 집합으로 보관해 그사이 빠진 화면은 소비하지 않고, 변경 신호가 잠긴 상태에서 왔으면 안정화 전 해제도 억제에 삼키지 않는다 (2026-09-11 재현 검사 2건).
- `isSettling`을 노출한다 — 컨트롤러는 안정화 중 수집을 멈춘다.

### CollectTrigger

- **인터페이스**: `start()` / `stop()` / `retarget(_:)` + 콜백 셋 — `onCollect()` / `onTerminating()` / `onAppTerminated(bundleID)`.
- **숨기는 것**: 창 이동 정착과 앱 전환·종료가 서로를 메우는 사실. 자동 저장 OFF에서도 돈다 — 창 연결·닫힌 환경 판정은 자동 저장과 별개다(F-03.6).

### MissionControlWatcher · ActiveSpaceWatcher

- Mission Control 닫힘 전이와 활성 Space 변화를 한 번으로 압축한 콜백. 컨트롤러가 진행 중 요청의 방문 대기·이동 안내를 먼저 재판정하고, 그 뒤 수집으로 보낸다.

### WorkspaceLibrary

- **인터페이스**: `saved(for:)` / `record(for:)` / `hasPendingChanges(for:)` / `observedBundleIDs(for:)` / `capture` / `collect` / `trackLinks` / `noteAppTerminated` / `markClosed` / `confirm` / `confirmAll` / `confirmLink` / `link(for:)` / `setAppEnabled` / `removeApp` / `removePlacement` / `remove(key:)` / `setAutoSave`. 파일에 쓰는 명령은 실제 보존 성공 여부를 돌려준다.
- **숨기는 것**: 작업 환경 키 규약, 마지막 저장본과 저장 대기 이력의 구별, 수동 저장·자동 저장 OFF→ON이 옛 관찰을 무효화하는 순서 번호, 같은 내용의 자동 저장 생략, 실행 중 창 연결의 수명과 어느 환경에서 창이 사라졌는지의 기록, 같은 환경에서 닫힌 자리의 제외 목록(파일 보존), 앱 포함·제외, 재실행 뒤 연결 없는 창을 같은 앱·화면·Space의 자리에 재대응하는 규칙, 읽기 실패·이후 버전 파일에서 모든 변경을 동결하는 금지, 쓰기 성공 뒤에만 상태를 공개하는 순서.
- 복원 엔진은 저장소 구조를 모른다 — 저장본·앱 선택·제외 목록·연결만 값으로 받는다.

### CaptureEngine

- **인터페이스**: `observe(창들, 작업 환경 화면들, Space snapshot?, 보존할 기록, 유효 연결, 제외 앱, 닫힌 자리) -> (창 위치 기록들, 화면 기록들, 새 연결, 관찰한 앱, 내장으로 옮긴 자리, 확인한 Space)`.
- **숨기는 것**: 중심점 판정(F-03.2), 창별 병합(F-03.3), 현재 Space만 확인한 것으로 기록하는 규칙, 비율 좌표 변환, 드리프트 방지. 전체화면·Split View·최소화·숨김은 기록하지 않는다.

### WindowMatching

- **인터페이스**: `assign(저장 자리들, 후보 창들) -> 자리 → 후보`. 전체 이동 거리 최소, 동률은 크기 차이·입력 순서. 7개 이하는 전수 탐색, 그 이상은 탐욕 배정.
- 복원의 창 대응(D3)과 재실행 뒤 수집의 자리 재대응이 같은 규칙을 쓴다.

### RestoreEngine

- **인터페이스**: `plan(저장본, 앱 포함 판정, 닫힌 자리, 화면들, 한 번 열거한 창들, 조회 실패 앱, Space snapshot?, 연결, 사용자 지정, 실행 중 앱, 옵션, 이미 요청한 실행·생성) -> 저장 창별 결정 + 화면 통째 건너뜀 + 앱별 실행·생성 필요`.
- **숨기는 것**: Space 조건(F-02.2), 창 대응(F-02.3), 창 부족 시 닫힌 환경·다시 열기 허용(F-02.4), 건너뜀 사유, 지문 검증(F-01.4). 이동·실행은 하지 않는다 — 결정만 낸다.
- **격리 자유** — 어느 액터에도 묶이지 않는 순수 정책 모듈.

### RestoreSession

- **인터페이스**: `start(origin, key, screens, environment)` / `resume(scope, …)` / `cancel(reason, onlyAutomatic:)` / `cancelItems(bundleID:)` / `cancelItem` / `chooseWindow` / `discardUnconfirmedChoices` / `drop` + 읽기 전용 `request`, `results`, `candidates(for:)`, `landings`.
- **숨기는 것**: 소스 고정, 저장 창별 결과 추적, 실행·생성을 요청당 한 번씩 보내고 다시 읽어 다시 판정하는 최대 3회 순서, 이동·실행 직전의 요청 유효성·잠금·사용자 조작 게이트, 재판정 범위(이벤트·잠금 해제·사용자)의 구별, 취소 이유. 환경(`Environment`)으로 옵션·잠금 판정·사용자 조작 판정·진단 기록을 주입받는다.
- ProfileStore·카드 상태를 소유하지 않는 MainActor 내부 타입이다. 요청은 메모리에만 있다.

### DesktopObservation

- **인터페이스**: `sample(of:includeSpaces:) -> (sequence, windows, unavailableBundleIDs, spaceAvailability?)` / `drain()` / `latestSequence`. 조회 실패 앱을 따로 돌려줘 창 부재를 닫힘으로 오판하지 않는다.

### SpacePlacement

- 저장된 `SpaceHint`, 회차 한정 runtime ID, 창 ID들을 각각 stable `SpaceSnapshot`의 위치 사실로 해석한다. 저장·복원·표시 정책은 넣지 않는다.

### SpacesSupport · ScreenLock

- 개별 Spaces 설정 판정(설정 값 + 관찰 교차 확인)과 잠금 삼상태 판정. 실물 판정은 컨트롤러에 클로저로 주입되어 테스트가 스텁을 넣는다.

### DiagnosticsLog

- 로컬 최근 100건, 반복 사례 dedup, 사용자 내보내기. 저장본·결과와 분리되어 기록 실패가 둘을 바꾸지 않는다.

### WindowMoveSource

- **인터페이스**: `observeWindowMoves(of:onSettled:)` (압축된 정착 1회) / `observeWindowInteractions(_:)` (원시 알림마다 창 ID). 사용자 조작 보호는 후자를 Plugback 자신의 이동 시각과 대조해 판정한다 — 추정이며 실기기 검증 항목이다.

### ScreenID · PortLocator (SystemScreenProvider 내부 개념)

- 식별자는 `CGDisplayCreateUUIDFromDisplayID`, 지문은 vendor/model/serial. 포트 위치는 IORegistry의 DisplayPort 전송 노드 EDID와 USB-C 포트 노드를 대응시켜 얻으며 표시용이다 (UNDOCUMENTED_APIS 8절).

### WindowGateway

- **인터페이스**: `standardWindows(of:)`(제목·창 ID 포함), `enumerationFailures()`, `move`, `unminimize`, `isRunning`, `openWindow`(기본 창 되살리기), `launch`(종료된 앱 실행), `openAdditionalWindow`(메뉴의 새 창 항목), `raise`. 새 메서드는 기본 구현이 있어 페이크가 최소로 남는다.
- 다른 앱의 창·프로세스를 만지는 유일한 모듈. actor이며 NSWorkspace 접근만 메인으로 홉한다.

### ProfileStore

- `workspaces.json`(버전 2)의 읽기·쓰기·손상 백업, 구버전 `profiles.json`의 읽기 전용 이전. 슬롯 키 규약은 이전 코드에만 남는다.

### PlugbackController

- **인터페이스**: 관찰 가능한 상태(화면 상태, 섹션·Space 그룹·화면 표시 이름, 대기·확인 항목, 마지막 결과, 복원 진행 중·화면 안정화 중, 권한, 복원 모드, 자동 저장, 최소화 옵션, 실험실 4종, 개별 Spaces 판정, 저장소 문제, 진단 기록) + 저장·복원·남은 창 복원·남은 복원 취소·직접 지정·창 확인·앱 포함/제외·기록 삭제·작업 환경 삭제·종료 전 저장 명령.
- **숨기는 것**: 배선 전부 — 작업 환경 전환의 확정·선택·요청 시작, 이벤트별 재판정 범위, 수집 조건(권한·안정화·복원 중·개별 Spaces), 복원 착지 위치의 이력 승격 방지, 사용자 조작·자기 이동의 대조, 설정 이전, 결과 수명(= 저장본 수명).

### MenuBarUI

- 카드는 `MenuBarExtra(.window)`, 「복원 확인」은 `Window` 씬, 설정은 `Settings` 씬. 표현 매핑은 `CardPresentation`이 맡고 App 테스트 타깃이 전 분기를 검증한다. 화면 표시 이름·Space 번호·대기 줄·사유 문구는 여기서만 만든다. 앱 목록은 화면마다 「지금 화면에 있는 앱 / 화면에 없는 저장 앱 / 제외한 앱」 세 묶음이며(F-05.3), 컨트롤러의 `ScreenSection`이 저장본과 마지막 관찰의 표준 창 목록에서 파생한다.
- 앱 델리게이트가 정상 종료 전 저장을 판정한다 — 실패하면 종료를 취소하고 재시도·저장 없이 종료를 묻는다.

## 3. 심 (Seam)

교체 지점은 **WindowGateway·WindowMoveSource·ScreenProvider·SpaceReading 네 프로토콜과 세 판정 클로저(`authorizationCheck`·`lockStateCheck`·`spacesPreferenceCheck`)**다. WindowGateway 페이크로 저장·복원 정책 전부를, ScreenProvider 페이크로 작업 환경 전환을, SpaceReading 페이크로 Space 판정을, 클로저로 게이트 정책을 실기기 없이 검증한다. 생성자 파라미터(ProfileStore 디렉터리, UserDefaults, 간격들, 진단 디렉터리)는 테스트 격리용이다.

## 4. 스택

- Swift + SwiftUI(`MenuBarExtra(.window)` + `Settings` 씬). AppKit은 어댑터(NSWorkspace·NSScreen·AX)에서만. macOS 13.0+, 샌드박스 미적용 (F-07).
- 외부 의존성 없음. 전부 시스템 프레임워크로 해결한다.

## 5. 패키지 경계

```
plugback/                    ← 이 레포 (MIT)
├── Package.swift            ← 루트 고정
├── Sources/PlugbackKit/     ← MenuBarUI를 제외한 위 모듈 전부
├── Sources/screen-probe/    ← 화면 식별자 스파이크 측정 도구 (실행 제품)
├── Tests/PlugbackKitTests/  ← 페이크 WindowGateway로 정책 검증
├── Tests/DesignReviewTests/ ← R1–R6·잠금 순서의 제품 계약 검사 (Scripts/check-product-restore.sh로 별도 실행)
├── Scripts/                 ← 재현 검사·창 조작 관찰 프로브
└── App/                     ← 메뉴바 앱. 로컬 패키지 참조
    └── PlugbackTests/       ← 표현 매핑(CardPresentation)·렌더 유닛 테스트 — 앱 호스트
```

- **PlugbackKit은 헤드리스 코어다.** 이 앱이 아닌 다른 앱(제작자의 별도 비공개 유료 앱 포함)이 `.package(url:)` 의존으로 얹힐 수 있다. 이 경계가 이 레포에 패키지 계층이 존재하는 이유다.
- **Package.swift는 레포 루트를 벗어나면 안 된다.** SPM은 git 의존성의 매니페스트를 루트에서만 찾는다. 옮기면 외부 소비자가 전부 깨진다.
- 릴리스는 semver git 태그로 한다. 외부 소비자는 태그로 버전을 고정한다.
- App/은 패키지 제품이 아니다. 외부 소비자의 빌드에 포함되지 않는다.

## 6. 마일스톤

세로 슬라이스. 각 단계가 끝나면 실기기에서 동작을 확인할 수 있다.

| M | 내용 | 스토리 |
|---|---|---|
| M1 | 메뉴바 뼈대 + 권한 온보딩 | US-010 |
| M2 | WindowGateway + 저장·수동 복원 + ProfileStore | US-002, 007 |
| M3 | ScreenID + 화면별 프로필 | US-003 |
| M4 | DisplayWatcher + 자동 복원 + 게이트·억제 | US-001, 009 |
| M5 | 복원 동작 시스템 노출(단축어, 기본 할당 없음)·설정 창(프로필 목록·로그인 항목)·카드 A/B 확정 (결과 사유 UI·체크박스는 M2에서 선반영) | US-006, 007, 008, 011, 012 |

**M1–M5 구현 완료 (2026-08).** 2026-09에는 A 상태 카드를 기본값으로 두고 A–D 레이아웃과 독립 색상 선택을 제공한다. **2026-09-11에 작업 환경·창별 기록 모델(D1–D9)을 구현했다** — 실기기 검증 항목은 [DEVICE_TEST_CHECKLIST.md](./DEVICE_TEST_CHECKLIST.md) 10절에 있다. 남은 것: §2 MenuBarUI의 실기기 검증 항목들, 아래 화면 식별자 스파이크.

화면 식별자의 실기기 스파이크(F-01.4). 측정 도구는 `swift run screen-probe` — 상황 전후로 실행해 UUID를 비교한다. 프로브는 배포 식별 로직(SystemScreenProvider)을 그대로 사용한다 — 다른 것을 재면 측정이 스파이크 질문에 답하지 못한다.
① 포트 변경 시 UUID 유지 — **통과** (2026-08-16 실측: 필립스 27E2F7901, 포트 교체 전후 UUID·지문 동일. 최대 미지수였던 항목) ② 동일 모델 2대 동시 연결·순서 교체 재연결 — 미측정 ③ 재부팅 후 유지 — 미측정 ④ 클램셸에서 내장 화면이 빠지는 목록이 Online인지 Active인지 — 미측정 ⑤ DisplayLink 독(보유 시 — 재연결마다 UUID가 바뀐다는 보고가 있어 무동작 처리 확인) — 미측정.
