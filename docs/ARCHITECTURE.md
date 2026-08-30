# Architecture

## Plugback

> **문서 관계**
> - [FUNCTIONAL_SPEC.md](./FUNCTIONAL_SPEC.md) — 이 설계가 만족시켜야 할 동작. 이 문서의 상위.
> - [CONTEXT.md](../CONTEXT.md) — 용어. 이 문서의 모든 용어는 여기를 따른다.
>
> 이 문서는 모듈 경계와 인터페이스만 정한다. 모듈 내부 구현은 구현자의 재량이다.

---

## 1. 설계 원칙

스펙의 복잡성은 네 군데에 몰려 있다. 각각을 깊은 모듈 하나에 가두고, 나머지는 얇게 유지한다.

1. **연결 이벤트의 노이즈** — 디바운스, 위상 게이트, 잠자기 억제 → DisplayWatcher
2. **접근성 API의 함정** — 좌표계 2개, 조용한 실패, 응답 없는 앱 → WindowGateway
3. **저장·복원 정책** — 병합, 건너뜀, 검증·재시도 → CaptureEngine / RestoreEngine
4. **Space 복원의 시간축** — 연결 직후 복원, 방문 대기, Space별 1회 완료 → RestoreSession

## 2. 모듈 맵

```
DisplayWatcher ──이벤트──▶ PlugbackController ◀──조작── MenuBarUI
CollectTrigger ──이벤트──▶      │
ActiveSpaceWatcher ──────▶      ├─▶ ProfileSlots ─▶ CaptureEngine · ProfileStore
                               ├─▶ RestoreSession ─▶ RestoreEngine
                               │         │
                               └─────────┴─▶ DesktopObservation
                                                ├─▶ WindowGateway
                                                └─▶ SpaceReader
RestoreSession ─▶ SpaceRelocator
PlugbackController ─▶ ScreenProvider (ScreenID 내장)
```

CaptureEngine은 게이트웨이를 모른다 — 이미 열거된 창 스냅샷을 받는 거의 순수 함수다.
저장·수집·예측과 모든 복원 회차의 창 열거는 같은 DesktopObservation을 통한다. RestoreEngine은
WindowGateway를 주입받되, Space 복원 범위와 무관하게 복원 세션이 한 번 열거한 값을 받는다.

### DisplayWatcher

- **인터페이스**: 콜백 둘 — `onExternalScreensAppeared()` (무페이로드 — 어느 화면인지는 소비자가 전체 동기화로 알아낸다. "어느 화면이 새로 왔나"는 발화 여부를 정하는 내부 계산이다) / `onExternalScreensRemoved(식별자들)` (**페이로드가 있다** — 사라진 화면은 이미 목록에 없어 소비자가 되물을 수 없다). 제거를 등장보다 먼저 보고한다 — 화면을 바꿔 끼울 때 확정이 재복원보다 앞서야 직전 배치를 잃지 않는다.
- **숨기는 것**: 이벤트 안정화 대기(F-01.2), 위상 게이트·잠자기 억제·잠금 미루기(F-01.3). (무효 해상도 필터는 ScreenProvider의 일이다.) 원시 화면 이벤트 3~6회를 의미 있는 이벤트 1회로 압축한다.
- US-009(창 튐 방지)는 전부 이 모듈 안에서 결판난다.
- 이 모듈이 다음 층으로 넘기기까지의 판정 순서 → [RESTORE_FLOW.md](./RESTORE_FLOW.md)

### CollectTrigger (실험실 · 자동 슬롯 전용)

- **인터페이스**: `start()` / `stop()` / `retarget(_:)` + 콜백 둘 — `onCollect()`(수집할 시점) / `onTerminating()`(마지막 확정 기회).
- **숨기는 것**: **신호원이 셋이라는 사실 전부.** 창 이동(직접 옮긴 것), 앱 전환(옵저버가 못 받는 앱·나중에 켠 앱), Mission Control 닫힘(비활성 Space의 화면 간 이동)이 서로를 메우지만, 컨트롤러가 아는 것은 「수집할 때가 됐다」 하나다. 전환 스로틀·이동 디바운스·Mission Control 닫힘 정착과 등록 대상 갱신이 여기 산다.
- 어댑터가 실제로 셋이라 이 seam은 지어낸 것이 아니다. 신호원이 더 생겨도 컨트롤러 쪽은 바뀌지 않는다.
- 주기 타이머가 아니다 — 사용자 이벤트에만 발화하므로 자리를 비우면 조용하다(F-07).
- 자동 슬롯이 꺼져 있으면 컨트롤러가 아예 만들지 않는다. 꺼진 수집 기능이 알림을 받고 있으면 "꺼짐"이 아니다.
- **ActivityWatcher**(앱 전환 압축)와 **MissionControlWatcher**(Mission Control 닫힘 압축)는 이 모듈의 구현 세부다 — 인터페이스에 나오지 않는다. 활성 Space 알림은 Space-aware 컨트롤러가 같은 수집 경로로 합친다.

### ProfileSlots

- **인터페이스**: `source(for:)` / `resolvedWithSpaces(for:)` / `targets(for:)` / `all` / `capture` / `collect` / `confirm` / `edit` / `remove` + 실험실 토글·자동 슬롯 반영 방식.
- **숨기는 것**: 화면 하나가 슬롯 둘을 갖는다는 사실 전부 — 키 규약, 복원 소스 판정(더 최근 것·동점은 수동, 선택한 방식에서는 현재 후보 우선), 씨앗 복사, 화면별 수집 후보의 수명, 즉시/분리 확정, 병합, 실험실 on/off가 후보 판정에 미치는 영향, 읽지 못한 파일에 쓰지 않는 금지(F-04.2). 프로필과 Space overlay는 저장된 슬롯·후보마다 `ResolvedProfile` 한 값으로 움직이며, JSON에는 프로필만 기록한다.
- **복원 엔진은 슬롯을 모른다** — `resolvedWithSpaces(for:)`가 화면당 같은 슬롯의 프로필·overlay 한 쌍으로 좁혀서 넘긴다.
- ObservableObject다. 컨트롤러가 변경을 자기 것으로 전달하므로 바인딩은 여전히 컨트롤러 하나만 본다.

### DesktopObservation

- **인터페이스**: `windows(of:)` / `drain()` / `stableSnapshot(for:)`.
- **숨기는 것**: 마지막 AX 창 열거의 window ID만 유효하다는 계약과, 복원 전에 먼저 시작한 저장·수집·예측 열거를 모두 끝내는 순서. Space snapshot은 반드시 같은 열거가 돌려준 window ID들로 만든다.
- MainActor 내부 타입이며 별도 프로토콜을 만들지 않는다. 컨트롤러와 RestoreSession이 같은 객체를 쓴다.

### RestoreSession

- **인터페이스**: `restoreAll`(연결·수동 복원) / `restoreVisited`(Space 방문) / `invalidate(screens:)` + 읽기 전용 방문 대기 조회.
- **숨기는 것**: 일반 Space·전체 화면 복원 범위, 일반 Space 사전 재배치와 검증, 연결 직후 방문 대기 생성, 현재 Space만 복원, 완료된 대상 제거, 새 창 열기 뒤 authoritative 창 열거 → 필요할 때만 stable snapshot → RestoreEngine 순서. Space 복원 범위가 모두 꺼져도 같은 복원 회차를 쓰되 private snapshot은 읽지 않는다.
- ProfileSlots를 소유하지 않는다. 컨트롤러가 고른 최신 `ResolvedProfile` 값만 받아 프로필과 Space overlay의 복원 소스를 섞지 않는다.
- 카드 상태를 소유하지 않는 MainActor 내부 타입이다. 결과는 컨트롤러에 돌려주고, 결과 수명·복원 중 게이트·새 화면 재요청·복원 뒤 수집과 예측은 컨트롤러가 맡는다.

### WindowMoveSource

- **인터페이스**: `observeWindowMoves(of:onSettled:)` 하나. 보증하는 것: 등록은 **멱등**, 빈 목록은 **해제**, 콜백은 **압축된 뒤에** 온다.
- WindowGateway와 **같은 seam의 다른 인터페이스**다. 게이트웨이는 요청/응답이고 이쪽은 수명주기가 있는 구독이라, 한 프로토콜에 섞으면 호출자가 알아야 할 사실이 두 종류가 된다.
- 실물 어댑터(AXWindowGateway)가 둘 다 만족하므로 "다른 앱의 AX는 어댑터 안뿐"이라는 불변식은 그대로다.

### WindowMoveObserver (AXWindowGateway 내부 개념 — 별도 심이 아니다)

- **인터페이스**: `observe(pids:onSettled:)` / 콜백 하나 — "창이 정착했다". 무페이로드다: 어느 창인지는 소비자가 어차피 전체 수집으로 알아낸다.
- **숨기는 것**: AX 옵저버 생성·실행 루프 등록·해제, 그리고 노이즈 압축(후행 디바운스). 알림은 **앱 요소**에 걸어 그 앱의 모든 창을 덮는다 — 등록 뒤에 열린 창도 포함된다.
- **게이트웨이가 소유한다.** 다른 앱의 AX를 만지는 것은 여전히 WindowGateway 어댑터 안뿐이라는 불변식이 유지된다 — 이 타입은 그 어댑터의 구현 세부다. 프로토콜에는 관찰만 노출되고 AX는 새지 않는다.
- 실행 루프에 붙으므로 MainActor다. 게이트웨이(actor)는 `MainActor.run`으로만 건드린다 — NSWorkspace를 다루는 방식과 같다.

### ScreenID (SystemScreenProvider 내부 개념 — 별도 타입이 아니다)

- 하드웨어 식별자 추출과 폴백(F-01.4). 식별에 실패한 화면은 `screens()` 결과에서 빠지고, 호출자는 그 화면을 복원하지 않는다.
- 화면 열거는 **ScreenProvider 심**(실물 SystemScreenProvider)이 맡고, identity 추출·지문·미러링 정규화는 그 구현 안에 산다 — 프로토콜 경계는 `screens() -> [ScreenInfo]` 하나다.
- 2026-08 문헌·실측 조사로 확정한 스킴:
  - 1차 키는 `CGDisplayCreateUUIDFromDisplayID` 문자열. macOS WindowServer 자신이 화면 배치 기억에 같은 UUID를 쓴다.
  - 저장 키 금지: `CGDirectDisplayID`(재시작·포트 변경에 불안정 — Apple 문서 명시), IORegistry `"EDID UUID"`(시리얼이 지워진 모델 지문이라 동일 모델 두 대가 같은 값).
  - UUID가 NULL인 화면은 목록에서 빠지고, 연결된 화면끼리 UUID가 충돌하면 뒤의 화면이 목록에서 빠진다. 어느 쪽도 대체 키로 강등하지 않는다 — 잘못된 프로필보다 무동작이 낫다.
  - vendor/model/serial 지문은 키가 아니라 **검증용**으로 함께 저장한다. UUID는 같은데 지문이 다르면 복원하지 않는다.
  - 미러링 세트는 주 화면으로 정규화한 뒤 식별한다. DisplayWatcher의 안정화 대기가 끝난 뒤에만 호출한다 — 확정 전에는 NULL이나 오답이 나온다.

### WindowGateway

- **인터페이스**: `standardWindows(of: 대상 앱들?) -> [창 정보]` (nil = 실행 중 전체 — 저장이 이 경로를 쓴다), `move(창, to: 좌표) -> 실제 좌표?`, `unminimize(창) -> 실제 좌표?`, `isRunning(앱)`, `openWindow(앱) async -> 창 존재 여부`. move·unminimize의 nil은 "창이 사라졌거나 앱이 거부했다" — 성공 반환값 대신 재판독을 돌려주는 것이 이 심의 일관된 처방이다. 실행 여부·새 창 열기는 건너뜀 사유의 구분과 예외 옵션에 필요하며, 창 열거와 같은 앱 집합을 봐야 하므로 창 세계의 일부로 둔다. 화면 열거는 여기 속하지 않는다 — ScreenProvider의 일이다. **창 ID는 마지막 열거가 돌려준 것만 유효하다** — 이전 열거의 ID를 들고 있지 마라.
- **숨기는 것**: 다른 앱의 창을 만지는 시스템 API 전체(접근성 + NSWorkspace). 창 열거(실행 중 앱 순회, F-06.1), 표준 창 필터, 전체화면·최소화 감지, AX 호출당 응답 대기 한도(F-02.4), 좌표계 통일, **새 창 열기 후 창이 실재할 때까지의 대기**(창이 비동기로 나타난다는 플랫폼 현실은 호출자가 모른다 — 등장 한도는 실물 어댑터의 보정 노브).
- **다른 앱의 창·프로세스를 만지는 유일한 모듈.** 각 어댑터가 자기 API의 좌표계를 통일 좌표계(좌상단 원점 전역)로 바꾼다 — NSScreen 뒤집기는 ScreenProvider, AX는 무변환. 바깥은 단일 좌표계만 본다.
- **격리 계약**: 심의 모든 메서드는 async이고, **구현이 자기 실행 흐름을 소유한다**. 실물 어댑터는 actor — AX 왕복(호출당 250ms 한도)이 메인 액터를 막지 않는다 (F-02.4). NSWorkspace 접근만 메인으로 홉한다. StrictConcurrency가 이 계약을 컴파일 타임에 지킨다.
- 프로토콜로 선언한다. 실물 어댑터와 테스트용 페이크, 어댑터 둘이 이 심을 실재하게 만든다.

### RestoreEngine

- **인터페이스**: 내부 `restore(선택된 프로필+Space overlay들, 화면들, 한 번 열거한 창들, Space snapshot?, 복원 범위, 옵션) -> 복원 회차 결과` + 내부 `predict(선택된 프로필+Space overlay, 화면?, 창들, Space snapshot?, 실행 집합, 복원 범위, 옵션) -> [앱별 복원 예측]`. 복원의 외부 진입점은 RestoreSession 하나다. 예측은 부수효과 없는 사전 판정이며 카드의 점이 그린다. 일치 보증은 식별자 정렬상 첫 화면 기준 — 뒷 화면은 중복 제거로 앱이 빠질 수 있다.
- **숨기는 것**: 복원 정책 전부. legacy와 Space-aware 창 선택, 건너뜀·방문 대기·판정 불가 판정(F-02.2 — 예측과 진실이 같은 선택 결과를 공유한다), 예외 옵션(최소화 꺼내기·새 창 열기), 이동·검증·재시도(F-02.3), 다중 화면 중복 제거(F-01.6), 지문 검증(F-01.4 — 불일치는 화면 단위 건너뜀 사유로 결과에 실린다), 이동·건너뜀·실패 사유 기록. 방문 대기·판정 불가처럼 이번 복원 회차에 결과가 없는 앱은 예측에도 넣지 않는다.
- WindowGateway를 주입받는다. 페이크 어댑터로 실기기 없이 정책 전부를 테스트한다 — 대기·타이밍은 심 뒤라 정책 테스트에 벽시계 대기가 없다(인터리빙 검증용 서스펜션 노브 제외).
- **격리 자유** — 어느 액터에도 묶이지 않는 순수 정책 모듈. 외부 소비자가 MainActor 홉 없이 쓸 수 있다 (§5 헤드리스 코어 약속).

### CaptureEngine

- **인터페이스**: 저장은 `(현재 창들, 기존 프로필) -> 병합된 새 프로필`, 수집은 `(현재 창들, 기존 프로필+Space overlay, Space snapshot?, 제외 앱들) -> 다음 후보 pair`.
- **숨기는 것**: 중심점 판정(F-03.2), 병합 규칙(F-03.3), 비율 좌표 변환(F-03.4), 드리프트 방지(F-08.4), 다른 화면으로 명확히 떠난 앱 제거와 비활성 single fullscreen 보충(F-08.3).
- 거의 순수 함수다. 비율 좌표 변환은 값 타입으로 분리해 RestoreEngine과 공유한다.
- **허용 오차 판정도 RestoreEngine과 공유한다.** 복원이 "제자리"로 본 차이를 저장이 "옮겨졌다"고 보면 두 엔진이 어긋나고, 그 틈으로 창이 회차마다 밀린다.

### ProfileStore

- **인터페이스**: `load() -> (프로필들, 문제?)`, `save(프로필들)`. 문제는 한 어휘 — 손상(백업 위치 포함) 또는 읽기 실패.
- **슬롯을 모른다.** 저장소는 키→프로필 사전일 뿐이고, 수동/자동의 구분은 키 규약(`<화면 식별자>` / `<화면 식별자>#auto`)으로 ProfileSlots가 만든다. 수동 키가 화면 식별자 그대로라 기존 파일이 그대로 읽히고, 실험을 걷어내도 마이그레이션이 필요 없다.
- **숨기는 것**: 파일 위치, 직렬화, 손상 시 백업·초기화(F-04.2). 알림 표시는 컨트롤러의 일이다.
- **읽기 실패는 첫 실행이 아니다** — 파일을 건드리지 않고 보고만 하며, 컨트롤러는 그 실행의 모든 저장을 거부한다(덮어쓰기 데이터 손실 방지). 알림을 닫아도 이 금지는 유지된다.

### PlugbackController

- **인터페이스**: 관찰 가능한 상태(화면 상태 — 연결됨(화면)·기억만(이름)·없음의 3상태 enum, 프로필 유무, 앱별 복원 예측, Space별 카드 표시 그룹, 마지막 복원 결과(결과 수명 = 프로필 수명), 복원 진행 중, 권한 상태, 복원 모드, 복원 옵션 2종(최소화 복원·새 창 열기), 실험실 토글 3종(자동 슬롯·일반 Space 복원·전체 화면 복원)과 자동 슬롯 반영 방식, 일회성 저장 확인, 저장소 문제 알림) + 명령(저장(async — 창 열거가 본체, 반환값 = 실행/거부 사유 — 확인 표시는 진짜 저장됐을 때만), 복원(async — 반환 시점 = 완료 시점, 반환값 = 실행/거부 사유), 대상 앱 토글·삭제, 모드 변경, 프로필 통째 삭제, 저장소 알림 확인). **복원 진행 중은 계약이다**: 저장·재복원은 명시적으로 거부되고, 진행 중 연결 이벤트는 종료 직후 1회 재복원으로 보류되며(소실 없음), 진행 중 삭제된 프로필의 결과는 기록되지 않는다 + 카드 열림 통지(`cardOpened` — 상태 동기화와 일회성 저장 확인 만료). **명령은 화면 상태를 스스로 동기화한다** — 호출 순서 의식이 없다.
- **숨기는 것**: 배선 전부 — 복원 세션의 정책은 없다. DisplayWatcher 이벤트 → (자동 모드면) RestoreSession, Space 방문 → 방문 대기가 있으면 RestoreSession, 명령 → CaptureEngine/RestoreSession, 설정 → 복원 범위·옵션, 마지막 복원 결과 보관. 자동 슬롯은 collect/confirm과 복원 소스 pool만 제어하고, 일반 Space·전체 화면 토글은 RestoreSession이 허용할 binding 종류만 제어한다. 수동 저장은 자동 슬롯과 무관하게 관련 실험실 토글이 켜져 있으면 Space overlay를 함께 잡는다. 세 실험실 토글이 모두 OFF이면 private Space snapshot을 읽지 않는다. **권한 게이트는 창을 만지는 명령(저장·복원)과 카드 열림 내부에 있다** (US-010 AC-2 — 프로필 편집·모드 변경은 AX를 쓰지 않으므로 게이트가 없다). 판정 어댑터는 앱이 주입하고, UI는 published 권한 상태에 바인딩한다(시스템 API를 직접 읽지 않는다).
- **슬롯은 여기서 다루지 않는다** (F-08). 규칙 전부가 ProfileSlots에 있고, 컨트롤러는 「이 화면의 프로필」만 묻는다. **RestoreEngine과 CaptureEngine도 슬롯의 존재를 모른다.**
- 한 번의 창·Space 관찰에서 나온 복원 예측·Space 그룹·Space 구성 차이·저장하지 않는 앱은 화면별 projection 한 값으로 교체한다. 프로필·복원 소스·마지막 결과는 각자의 수명에서 파생해 `ScreenSection`을 만들 때 붙이며 projection에 복사하지 않는다.
- UI 없이 완결되는 헤드리스 파사드다. UI는 이 상태의 표현일 뿐이며, 어떤 UI든 여기에 바인딩만 하면 된다.

### MenuBarUI

- 상태 표시, 동작 버튼, 대상 앱 체크박스, 복원 모드, 단축키(F-05), 권한 게이트(F-06.2), 로그인 항목(F-06.3). 전부 PlugbackController의 상태·명령에 바인딩한다.
- 권한·단축키·로그인 항목은 얇은 유틸로 취급한다. 모듈로 키우지 않는다.
- **표현 매핑은 CardPresentation으로 분리**되어 App 유닛 테스트 타깃(PlugbackTests)이 전 분기를 검증한다 — 문구는 앱의 것, 헤드리스 코어에 UI 문자열을 넣지 않는다. 유닛으로 못 잡는 것은 실기기 검증 항목이다: ① `MenuBarExtra(.window)` 재열림마다 `onAppear`가 발화하는가 (US-002 AC-1의 메커니즘) ② LoginItem의 릴리스 전용 분기 (F-06.3 — `#if !DEBUG`라 개발 빌드가 실행하지 않는다).
- 컨테이너는 `MenuBarExtra(.window)`. 우려 셋 중 ③ 프로그램적 열기는 요구사항 분석으로 해소 — 스펙은 카드를 자동으로 열 것을 요구하지 않는다(자동 복원은 카드가 닫힌 채 일어나고, 결과는 열었을 때 보이면 된다). 남은 실기기 검증: ① 화면 구성 변경 시 패널 위치 ② 결과 스트립 유무로 카드 높이가 변할 때의 애니메이션. 둘이 막히면 `NSPanel` + `NSHostingView`로 후퇴한다. (2026-08 메뉴바 앱 11종 조사: 카드형 드롭다운은 전부 커스텀 패널이었고 `.window` 선례가 없었다)
- 카드 7존: 헤더(화면 이름·프로필 상태) · **저장소 알림(조건부)** · **지문 불일치 경고(조건부)** · 결과 스트립(요약 + 앱별 사유 한 줄) · 대상 앱 목록 · 액션 · 푸터(자동 복원 토글·설정·종료). 액션과 목록의 상하 순서는 미결 — 프로토타입 A/B 변형(prototypes/dropdown-card.html) 참조, M5에서 결정.
- 조사에서 온 고정 결정: 결과 스트립은 표본에 선례가 없는 고유 설명 경로라 유지한다. 마지막 복원 결과는 카드 표시 여부와 독립적으로 보관한다. 빈 상태에서 카드를 비우지 않는다(마지막 화면과 프로필 유무를 남기고 버튼만 비활성). 권한 미승인은 카드를 통째로 교체한다. Dock 아이콘은 `LSUIElement` 고정 숨김.

## 3. 심 (Seam)

교체 지점은 **WindowGateway·WindowMoveSource·ScreenProvider·SpaceReading·SpaceRelocating 다섯 프로토콜과 권한 판정 클로저(`authorizationCheck`)**다. (생성자 파라미터 심 — ProfileStore 디렉터리, UserDefaults, DisplayWatcher 간격 — 은 테스트 격리용이지 교체 지점이 아니다.) WindowGateway 페이크로 두 엔진의 정책 전부를, ScreenProvider 페이크로 컨트롤러의 화면 상태 정책을, SpaceReading·SpaceRelocating 페이크로 private Space 판독과 visible drag 정책을, 권한 클로저로 게이트 정책을 실기기 없이 검증한다. RestoreSession과 DesktopObservation은 교체 대상이 아닌 MainActor 내부 타입이다. 어댑터가 하나뿐인 곳(ProfileStore 등)에는 여전히 가상의 심을 만들지 않는다.

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
└── App/                     ← 메뉴바 앱. 로컬 패키지 참조
    └── PlugbackTests/       ← 표현 매핑(CardPresentation) 유닛 테스트 — 앱 호스트
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

**M1–M5 구현 완료 (2026-08).** 남은 것: 카드 A/B 확정(§2 미결), §2 MenuBarUI의 실기기 검증 항목들, 아래 화면 식별자 스파이크.

화면 식별자의 실기기 스파이크(F-01.4). 측정 도구는 `swift run screen-probe` — 상황 전후로 실행해 UUID를 비교한다. 프로브는 배포 식별 로직(SystemScreenProvider)을 그대로 사용한다 — 다른 것을 재면 측정이 스파이크 질문에 답하지 못한다.
① 포트 변경 시 UUID 유지 — **통과** (2026-08-16 실측: 필립스 27E2F7901, 포트 교체 전후 UUID·지문 동일. 최대 미지수였던 항목) ② 동일 모델 2대 동시 연결·순서 교체 재연결 — 미측정 ③ 재부팅 후 유지 — 미측정 ④ 클램셸에서 내장 화면이 빠지는 목록이 Online인지 Active인지 — 미측정 ⑤ DisplayLink 독(보유 시 — 재연결마다 UUID가 바뀐다는 보고가 있어 무동작 처리 확인) — 미측정.
