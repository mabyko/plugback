# 활성 Space 기반 복원 구현 계획

## Plugback

> **문서 관계**
> - [FUNCTIONAL_SPEC.md](./FUNCTIONAL_SPEC.md) — 현재 제품 동작의 기준. 이 계획이 구현·검증되기 전까지 본 계획보다 우선한다.
> - [ARCHITECTURE.md](./ARCHITECTURE.md) — 현재 모듈과 interface. 새 seam은 실기기 게이트 통과 뒤에만 반영한다.
> - [RESTORE_FLOW.md](./RESTORE_FLOW.md) — 현재 복원 순서. 활성 Space 흐름이 제품에 들어갈 때 함께 갱신한다.
> - [UNDOCUMENTED_APIS.md](./UNDOCUMENTED_APIS.md) — 비공식 이름의 목록과 fail-closed 정책.
> - [research/mission-control-spaces-on-external-screens.md](./research/mission-control-spaces-on-external-screens.md) — 공개 문서, 외부 사례, 로컬 실측 근거.

- 상태: **P1–P5.6 구현 완료 · regular Space 자체의 수집·수동 재배치 통과 · 자동 재연결 1/3 통과**
- 작업 브랜치: `feature/active-space-restore`
- 작성일: 2026-08-27
- 적용 방식: 실험실 · 기본 꺼짐

---

## 1. 결정

비활성 Space의 창을 한 번에 열거해 전부 복원하는 원안은 폐기한다. 현재 macOS와 Plugback 앱 신원에서는 비활성 Space의 raw 창 membership은 보이지만, 이동 가능한 AX 표준 창이 열거되지 않는다.

기본 복원은 다음 방문 기반 흐름이다.

> macOS 또는 사용자가 외장 화면의 Space를 활성화하면, Plugback은 그 순간 보이는 대상 앱의 창만 해당 Space의 저장된 위치로 복원한다.

`Desktop N`과 runtime SID는 저장하지 않는다. 2026-08-29의 A → B → A 실기기에서 외장 regular Space 자체가 내장 화면에 남는 새 failure mode가 확인돼, 실험실 경로에는 **저장된 opaque name의 비활성 regular Space를 Mission Control의 보이는 drag로 목표 화면에 되돌리는 preflight**를 추가한다. Space 생성·삭제·전환, SkyLight write, type `4` 직접 drag는 하지 않는다.

regular Space의 화면 소속은 앱 binding에서만 간접 추론하지 않는다. 자동 저장이 켜져 있으면 연결된 외장 화면의 식별 가능한 type `0` Space 전체를 메모리 overlay에 함께 담는다. 따라서 창이 없는 Space도 같은 프로세스 안에서는 복구 대상이 된다.

## 2. 실측 기준선

환경: macOS 26.5.2, Xcode 26.6, 「각각의 Space가 있는 디스플레이」 켬, Plugback Debug 앱의 기존 서명·bundle ID 사용.

| 상태 | Space topology | 앱·AX 표준 창 | frame | AX↔CG↔Space join |
|---|---:|---:|---:|---:|
| 활성 일반 Space | 가능 | 가능 | 가능 | 단일 type `0`으로 성공 |
| 비활성 일반 Space | 가능 | 불가능 | 불가능 | AX 창이 없어 불가능 |
| 활성 native fullscreen | 가능 | 가능 | 가능 | `AXFullScreen=true`, 단일 type `4`로 성공 |
| 비활성 native fullscreen | type `4` 존재 감지 | 불가능 | 불가능 | AX 창이 없어 불가능 |

통제 실험은 다음 결과를 냈다.

- 내장 화면의 일반 Space 2개와 외장 화면의 일반 Space 2개를 화면별로 구분했다.
- 외장 Desktop 4에 Finder와 Zed를 두자 raw 창 수가 `5 → 8`로 늘었지만 두 앱은 AX 목록에 나타나지 않았다.
- Desktop 4를 활성화하자 Finder와 Zed 모두 frame, CGWindowID, 단일 type `0` membership이 연결됐다.
- Zed native fullscreen Space는 비활성일 때도 별도 type `4`로 보였다.
- Zed fullscreen Space를 활성화하자 `AXFullScreen=true`, frame readable, 단일 type `4` membership으로 연결됐다.
- 모든 private symbol이 열렸고, 연속 두 snapshot은 동일했으며, 재빌드 뒤 Accessibility 신뢰가 유지됐다.
- 내장 화면에서 새로 만든 비활성 regular Space를 방문하지 않고 A로 옮긴 뒤 다시 내장 화면, 다시 A로 왕복했다. 같은 runtime SID와 opaque name이 세 위치에서 유지됐고 local order만 화면 배열에 맞게 바뀌었다.
- 이 비활성 Space drag는 `activeSpaceDidChange`와 앱 활성·비활성 알림을 내지 않았다. Dock AX observer에서는 Mission Control 회차마다 `AXSelectedChildrenChanged → AXUIElementDestroyed → AXSelectedChildrenChanged`가 반복됐고, 닫힘을 1회 수집 신호로 압축할 수 있었다.

따라서 “Space 자체를 안다”와 “그 안의 창을 안전하게 움직일 수 있다”는 별도 capability다. 전자는 비활성 상태에서도 가능하지만 후자는 활성 상태에서만 가능하다.

## 3. 사용자에게 보일 동작

초기 실험실 버전은 다음처럼 동작한다.

```text
외장 화면 연결
  └─ 「일반 Space 복원」 ON이고 저장된 비활성 regular Space가 다른 화면에 남았으면
      └─ Mission Control visible drag → stable snapshot 검증
  └─ 「일반 Space 복원」 ON이면 현재 활성 Space의 창 위치 복원

사용자가 다른 외장 Space로 전환
  └─ Space 변경 알림 수신
      └─ topology 안정화 확인
          └─ 현재 활성 Space에 묶인 대상 앱만 복원

방문한 single native fullscreen (처음 본 앱 포함)
  └─ 「전체 화면 복원」 ON이면
      └─ 복원 때 일반 창으로 전환 → 목표 외장 화면으로 이동 → fullscreen 재생성

Split View / 판정 불명 type 4
  └─ 감지하고 그대로 둠
```

- 수동 슬롯: 사용자가 각 Space를 연 상태에서 「지금 레이아웃 저장」을 한 번씩 누르면, 방문한 Space의 앱 위치와 확인된 fullscreen 의도가 기존 프로필에 병합된다. 자동 슬롯과 무관하다.
- 자동 슬롯: 이 토글이 켜져 있으면 Space 방문·창 이동뿐 아니라 Mission Control을 닫을 때도 수집한다. 현재 활성 Space의 명확한 표준 창과 연결된 외장 화면의 식별 가능한 regular Space 전체가 후보이며, regular Space는 앱이나 방문이 없어도 포함된다.
- 일반 Space 복원: 실험실의 별도 토글이다. Space 자체의 화면 소속과 Space별 창 위치를 함께 다루며 자동 슬롯 OFF에서도 수동 슬롯으로 동작한다.
- 전체 화면 복원: 실험실의 별도 토글이다. 확인된 single native fullscreen만 재생성하며 일반 Space 복원·자동 슬롯과 독립이다.
- 복원 모드가 자동이면 연결 직후의 활성 Space와 이후 방문한 Space를 자동 복원한다.
- 복원 모드가 수동이면 「지금 레이아웃 복원」은 현재 활성 Space만 다룬다.
- single fullscreen은 처음 본 앱도 자동 슬롯 후보에 등록한다. 기존 일반 위치가 있으면 그 frame을 유지하고, 처음 본 fullscreen이면 현재 화면 bounds를 임시 frame으로 쓴다. 복원은 fullscreen Space 자체를 옮기지 않고 일반 창으로 되돌린 뒤 목표 외장 화면에서 다시 만든다.
- Split View, 같은 앱의 다중 창, 판정 불명 type `4`는 움직이지 않는다.

사용자는 모든 Space를 한 번에 순회하도록 강제받지 않는다. 평소처럼 Space를 열 때 그 Space가 복원된다.

## 4. 절대 지킬 규칙

1. **SkyLight로 Space를 쓰지 않는다.** Space 변경 함수를 로드하지 않고 생성·삭제·전환하지 않는다. 유일한 예외는 실험실에서 검증된 Mission Control regular thumbnail visible drag다.
2. **전역 번호를 저장하지 않는다.** `Desktop N`, global order, raw SID, CGWindowID는 프로필이나 UserDefaults에 기록하지 않는다.
3. **type `4`를 직접 drag하지 않는다.** regular Space 이동에 따라 macOS가 같은 fullscreen Space를 함께 옮길 수는 있다. 이때 SID·kind·name·membership을 전후 검증한다. 따라오지 않은 확인된 single fullscreen은 기존처럼 windowed → 목표 frame → fullscreen으로 재생성한다. Split View·알 수 없는 type·`AXFullScreen` 불명은 움직이지 않는다.
4. **켜진 복원 범위의 Space binding은 추측하지 않는다.** 현재 Space를 확실히 대응하지 못하면 해당 대상 앱만 건너뛴다. 해당 범위 토글이 OFF이면 그 binding은 없는 것처럼 기존 창 복원 규칙을 쓴다.
5. **내장 화면 배치를 저장하지 않는다.** 내장 Space 레코드는 목표로 사용하지 않는다. 다만 저장 대상 창이 내장 화면에 밀려 있으면 목표 외장 화면으로 회수할 수 있다.
6. **기존 기능을 보존한다.** 실험실이 꺼졌거나 private reader가 로드되지 않으면 현재 flat 프로필 동작과 테스트 결과가 그대로다.
7. **오버레이는 먼저 영속화하지 않는다.** 첫 vertical slice는 같은 Plugback 프로세스 안의 분리·재연결만 지원한다.
8. **같은 bundle의 다중 Space 창은 v1에서 추측하지 않는다.** 한 bundle이 서로 다른 Space에 관찰되면 해당 bundle을 unresolved로 둔다.
9. **꺼진 앱을 실행하지 않는다.** fullscreen 의도도 실행 중이며 표준 창 하나가 확정될 때만 적용한다.
10. **일반화한 Mission Control 순서를 아직 약속하지 않는다.** A → B → A의 destination-tail drag는 저장 순서를 보존했지만, 중간 삽입은 별도 실기기 사례가 생길 때 구현한다. fullscreen 전환 순서는 직렬화하고 새 type `4`의 좌우 순서는 macOS가 정한다.
11. **복원 전 저장을 금지한다.** 재연결 뒤 아직 복원할 binding이 남은 Space를 처음 열었을 때는 복원부터 하고, 그 결과를 어질러진 현재 배치로 수집하지 않는다.
12. **민감한 식별자를 로그에 남기지 않는다.** 진단 출력은 기존처럼 hash와 같음/변경/중복만 쓴다.

## 5. 최소 모델

기존 `Profile`과 `TargetApp.unitRect`가 frame의 유일한 진실이다. Space별로 frame을 복제하지 않는다.

```text
SpaceHint                       // Codable 아님
  opaqueName: String            // 해당 화면에서 non-empty·unique일 때만
  localOrderHint: Int           // identity가 아니라 진단 힌트

SpaceBinding                    // bundle당 하나
  regular(SpaceHint)
  unresolved(SpaceBlockReason)

SlotSpaceOverlay               // 메모리 전용
  byBundle: [String: SpaceBinding]
  regularSpaces: [SpaceHint]   // 화면에 속해야 하는 type 0 전체; 앱 없어도 유지

ResolvedProfile
  profile: Profile
  overlay: SlotSpaceOverlay?
```

live snapshot은 현재 호출에서만 쓰는 다음 값을 가진다.

```text
SpaceSnapshot
  displays
    screenID
    spaces
      runtimeID
      opaqueName?
      localOrder
      type
      isCurrent
  membershipsByWindowServerID

SpaceRelocation                 // 저장하지 않는 한 회차 명령
  sourceScreenID
  sourceLocalOrder
  destinationScreenID
  expectedSourceCount
  expectedDestinationCount
```

- `runtimeID`와 `windowServerID`는 메모리 밖으로 나가지 않는다.
- `opaqueName`이 비거나 같은 화면에서 중복이면 binding을 만들지 않는다.
- unique name이 같으면 local order가 바뀌어도 같은 Space로 본다. local order는 충돌 진단에만 쓴다.
- 같은 이름이 다른 화면에만 나타나면 stranded로 보고 건너뛴다.
- membership이 0개 또는 2개 이상이면 sticky/불명 상태이므로 unresolved다.

## 6. 모듈과 seam

```text
ActiveSpaceWatcher ──무페이로드 이벤트──▶ PlugbackController
MissionControlWatcher ─▶ CollectTrigger ──수집 이벤트──┘
                                              ├─ ProfileSlots — profile + overlay
                                              ├─ RestoreSession — 방문 대기 + 복원 회차
                                              │    ├─ RestoreEngine — 창 복원
                                              │    └─ SpaceRelocator — Mission Control visible drag
                                              └─ DesktopObservation
                                                   ├─ WindowGateway — AX 창 + 임시 ID
                                                   └─ SpaceReader — stable snapshot
```

### SpaceReader

새 deep module이다. caller가 알아야 할 interface는 하나만 둔다.

```text
stableSnapshot(windowServerIDs:) async -> available(SpaceSnapshot) | unavailable
```

implementation 안에 다음 복잡성을 숨긴다.

- `dlopen`/`dlsym`
- private dictionary 형식 검증
- 화면 UUID 매핑
- type·name·현재 Space·window membership 읽기
- raw snapshot 연속 두 번 비교
- 심볼 부재, 반환 형식 변화, 불안정 상태의 fail-closed 처리

실물 adapter, unavailable adapter, 테스트 fake가 같은 seam을 쓴다. private 형식은 controller나 engine에 새지 않는다.

### SpaceRelocator

앱은 Release에도 `MissionControlSpaceRelocator`를 주입하되, 일반 Space 복원 실험실 토글이 켜졌을 때만 호출한다. `SpaceRelocationPlanner`는 저장된 regular hint가 목표 외장 화면이 아닌 곳에 정확히 하나 있고, 비활성이며, source에 다른 regular Space가 남을 때만 한 건을 만든다. 실물 adapter는 `mc.display`의 `AXDisplayID`, 화면별 `mc.spaces.list` child 순서와 stable snapshot의 local order가 정확히 맞을 때만 destination tail로 pointer drag를 합성한다.

호출 성공값을 믿지 않는다. RestoreSession이 같은 runtime SID·kind·opaque name의 목표 화면 이동, 전체 Space 집합, current 상태, 다른 regular Space 소속·상대 순서, 읽은 window membership 불변을 새 stable snapshot으로 확인한 뒤에만 다음 Space를 처리한다. type `4`의 화면 소속 변화는 macOS가 regular Space와 함께 옮긴 경우에만 허용한다. 실패하면 기존 방문 기반 창 복원으로 내려가며 자동 retry·rollback·Space 삭제는 하지 않는다.

### DesktopObservation

컨트롤러와 RestoreSession이 창을 따로 열거해 임시 window ID의 수명을 깨지 않도록 `windows(of:)`, `drain()`, `stableSnapshot(for:)` 세 동작을 한곳에 둔다. 별도 protocol은 만들지 않는다. 복원 시작 전에는 먼저 진행 중이던 저장·수집·예측 열거를 끝내고, Space 범위와 무관하게 같은 authoritative 열거를 RestoreEngine에 넘긴다. stable snapshot은 Space 범위가 하나라도 켜졌을 때만 같은 window ID로 만든다.

### RestoreSession

연결 직후와 수동 복원은 `restoreAll`, Space 활성화는 `restoreVisited`로 들어간다. 선택된 profile+overlay 값만 받아 새 창 열기, authoritative 창 열거, 일반 Space 사전 재배치, 방문 대기 생성·가지치기, 현재 Space 복원, 완료 제거를 실행한다. Space 범위가 모두 꺼져도 별도 legacy 진입점으로 갈라지지 않고 같은 RestoreEngine 복원 회차를 쓴다. `restoreVisited`도 이전 snapshot 불안정이나 차단 뒤 안전해진 regular Space를 놓치지 않도록 사전 재배치를 다시 시도한다. ProfileSlots와 카드 상태는 소유하지 않으며, 화면 저장·확정·삭제가 배치를 다시 선언하면 `invalidate(screens:)`로 그 화면의 방문 대기만 버린다.

### WindowGateway

기존 `WindowInfo`에 마지막 AX 열거에서만 유효한 optional `windowServerID`를 붙인다. 실물 `AXWindowGateway`가 `_AXUIElementGetWindow`로 채운다. 저장하지 않으며 join 실패는 nil이다.

전체화면 상태는 Space 경로에서 `windowed | fullscreen | unknown`의 세 값으로 다룬다. 기존 `isFullscreen` 호출은 source compatibility를 유지하되, Space-bound 창은 `unknown`일 때 움직이지 않는다. 확인된 fullscreen 의도를 실행할 때만 raw `AXFullScreen`을 쓰고, 실제 AX 상태가 바뀔 때까지 최대 8초 기다린다.

### ActiveSpaceWatcher

공개 [`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)을 관찰한다. 이 알림은 payload가 없으므로 callback도 무페이로드이며 controller가 전체 snapshot을 다시 읽는다.

별도 protocol은 만들지 않는다. notification 구독·해제와 실측으로 정할 짧은 후행 debounce만 숨기는 내부 module이면 충분하다. 실험실이 꺼져 있으면 observer도 존재하지 않는다.

### MissionControlWatcher

비활성 regular Space의 생성·화면 간 drag는 공개 Space 변경 알림과 앱 전환 알림을 내지 않는다. `CollectTrigger` 내부의 이 module은 Dock AX tree에서 `mc`가 나타난 회차만 기억하고, tree가 사라진 뒤 0.5초에 수집을 한 번 호출한다. 계속 도는 타이머는 없고, 자동 슬롯이 꺼지면 AX observer도 제거한다. Dock AX tree가 바뀌거나 권한이 없으면 이 신호만 조용히 빠지며 기존 Space 방문·창 이동·앱 전환 수집은 남는다.

### ProfileSlots

overlay는 복원 소스를 고르는 `ProfileSlots`가 소유한다. 저장된 슬롯과 후보는 각각 profile+overlay를 `ResolvedProfile` 한 값으로 들고 있어 서로 다른 소스에서 섞일 상태가 없다. JSON에는 profile만 기록한다.

| 동작 | profile과 overlay |
|---|---|
| 수동 저장 | 같은 창 선택 결과로 manual pair를 갱신하고 candidate pair를 폐기 |
| 수집 | CaptureEngine이 같은 base에서 candidate pair를 만들고, 외장 화면의 unique non-empty regular Space 목록과 비활성 single fullscreen을 함께 반영 |
| 확정 | candidate pair를 auto로 이동 |
| seed | manual pair를 auto로 복사 |
| 대상 앱 추가·편집·삭제 | 두 슬롯과 candidate 모두 같은 bundle을 처리 |
| 프로필 삭제 | 해당 화면의 슬롯 pair와 candidate를 삭제 |
| 실험실 끄기 | candidate pair 폐기, private watcher 중지 |

### RestoreEngine

엔진은 `ResolvedProfile`과 한 번 열거한 `[WindowInfo]`, stable snapshot을 받아 bundle별로 단 하나의 경로를 고른다.

| 조건 | 결과 |
|---|---|
| overlay 없음 | 기존 legacy 경로 |
| regular binding이 현재 외장 Space와 unique하게 일치 | 정확히 join된 창만 복원 |
| binding이 다른 비활성 Space에 있음 | 방문 대기로 남기고, Space 활성화 때 재시도 |
| name 소실·중복, stranded, join 0/2+, reader unavailable | 해당 bundle만 `spaceUnavailable` |
| unresolved | 해당 bundle만 `spaceUnavailable` |
| regular binding의 창이 fullscreen이 됨 | 사용자 상태를 보호하고 해당 bundle만 `fullscreen` |
| fullscreen binding, 목표 화면의 single type `4` 확인 | `fullscreen`으로 완료 |
| fullscreen binding, 다른 화면의 single type `4` | fullscreen 해제 → 목표 frame 이동 → fullscreen 진입 |
| fullscreen binding, 현재 windowed 표준 창 하나 | 목표 frame 이동 → fullscreen 진입 |
| Split View·다중 창·fullscreen unknown | 움직이지 않고 `fullscreen` 또는 unavailable |
| 화면 지문 불일치 | 기존처럼 화면 전체 건너뜀 |

Space binding이 있는 bundle은 같은 실행에서 legacy 경로로 내려가지 않는다.

## 7. 한 회차의 순서

### 연결 직후

```text
1. DisplayWatcher 안정화와 기존 위상 게이트 통과
2. 연결된 외장 화면과 선택된 profile+overlay 확정
3. 다른 화면의 비활성 regular binding을 한 건씩 visible drag하고 매번 stable snapshot 검증
4. overlay가 가리키는 regular Space들을 방문 대기로 표시
5. 현재 활성 Space에 해당하는 binding만 복원
6. 나머지는 사용자가 해당 Space를 활성화할 때까지 유지
```

### Space 활성화

```text
1. ActiveSpaceWatcher 이벤트 압축
2. 화면 목록 동기화
3. 현재 활성 Space가 연속 두 snapshot에서 같은지 확인
4. 방문 대기 binding이 있으면 복원부터 실행
5. 일반 창 성공·제자리 또는 목표 화면의 single fullscreen 확인이면 방문 대기 종료
6. 앱이 꺼져 있거나 reader가 일시 unavailable이면 다음 방문까지 방문 대기 유지
7. 복원 회차가 끝난 뒤에만 자동 슬롯 수집 허용

fullscreen 진입의 AX 상태 변화만으로는 방문 대기를 끝내지 않는다. 다음 stable snapshot에서 목표 화면의 단일 type `4` membership을 확인해야 완료한다. current Space를 바꾸는 전환은 stable snapshot 한 회차에 하나만 시도한다.
```

### 창 열거와 ID 수명

복원 한 pass는 다음 순서를 지킨다.

```text
1. 새 창 열기 옵션의 polling을 먼저 끝냄
2. 대상 bundle 전체 AX 창을 딱 한 번 열거
3. 그 결과의 windowServerID로 stable SpaceSnapshot 생성
4. 순수 planner가 창을 선택
5. 같은 열거에서 받은 gateway window ID로 move·검증·1회 재시도
6. 모든 move가 끝날 때까지 다른 standardWindows 열거 금지
```

capture·collect·prediction에서 이미 시작된 창 열거가 있으면 restore의 authoritative 열거 전에 끝까지 기다린다. 새 actor 계층 대신 MainActor의 작은 `DesktopObservation`이 in-flight counter와 drain을 소유하고 컨트롤러와 RestoreSession이 함께 쓴다.

## 8. 단계별 작업

각 단계는 앞 단계의 GO를 통과한 뒤에만 시작한다. 단계별로 별도 검토 가능한 commit을 만든다.

### P0 — 앱 신원 진단 프로브: 완료

범위:

- `App/Plugback/SpaceProbe.swift`
- `App/Plugback/PlugbackApp.swift`

확인:

- 화면별 일반 Space topology
- 비활성 일반 Space AX 열거 실패
- 활성 일반 Space frame/join 성공
- 비활성 type `4` 존재 감지
- 활성 fullscreen Zed의 `AXFullScreen=true`와 type `4` join
- 연속 snapshot 안정성과 재빌드 후 TCC 유지

결정: 비활성 one-pass 원안 STOP, 활성화 기반 방향 GO.

### P1 — Space identity와 이벤트 실기기 게이트

제품 코드는 만들지 않고 진단 프로브만 사용한다.

측정 행렬:

1. 내장 Space 하나 추가 전후 외장 Space name·화면 소속·local order 비교
2. 자동 재정렬 끔/켬에서 방문 순서를 바꾼 뒤 같은 값 비교
3. 같은 포트 분리·재연결을 3회 반복
4. 재연결 1.5초·5초·15초 시점의 topology 안정성 비교
5. 외장 Space가 내장 화면에 남은 stranded 상태 식별
6. 일반 ↔ fullscreen 전환·해제에서 type `0 ↔ 4` 확인
7. Space 변경 알림과 실제 current Space 변경의 상관관계·필요 debounce 측정

진행 기록(2026-08-27):

- 외장 일반 Space를 번갈아 9회 전환했다. 각 알림 직후 재조회한 current Space가 실제 전환과 일치했고, 연속 두 snapshot은 모두 같았다. 이 범위에서는 추가 debounce가 필요하지 않았다.
- 내장 화면에 일반 Space 1개와 Slack native fullscreen Space 1개를 추가하자 내장 topology는 type `0` 3개 + type `4` 1개로 읽혔다. 활성 Slack Space는 type `4`, `isCurrent=true`였고, fullscreen 해제 뒤 해당 type `4` 레코드가 사라졌다.
- 외장 두 일반 Space의 global order는 `3/4 → 5/6 → 4/5`로 바뀌었지만, 화면 안 local order `1/2`, 화면 소속, non-empty name은 계속 그대로 대응했다. global order가 identity가 아님을 실측했다.
- 같은 포트 재연결 3회에서 외장 화면과 두 일반 Space의 name·local order는 재연결 알림 순간부터 유지됐다. 두 번째 회차의 raw membership은 알림 순간 `6/0`, 약 2초 뒤 `25/5`였고 이후 표본에서 같았다. 세 번째 회차는 알림 순간 `4/1`, 다음 1초대 표본에서 `23/5 → 25/5`로 안정됐다. 즉시 two-read만으로는 창 이관 완료를 판정할 수 없고 1.5초 후행 대기가 유효한 후보로 남았다.
- 두 번째 분리 상태에서는 외장 첫 Space의 name이 사라지고 그 창들이 내장 현재 Space에 합쳐진 것으로 보였다. 외장 두 번째 Space는 같은 name을 유지한 채 내장 local order `4`의 독립 Space로 남았고, 15초 뒤에도 같았다. 재연결하면 두 Space 모두 원래 외장 화면으로 복귀했다.
- 같은 포트 3회 identity 게이트는 통과했다.
- 위 Space 전환 9회와 같은 포트 재연결 3회는 시스템 설정의 “Spaces를 최근 사용 내역에 따라 자동으로 재정렬”이 켜진 조건이었다. ON 조건에서는 방문 순서를 바꿔도 외장 Space의 name·local order가 유지됐다.
- 자동 재정렬 OFF 뒤 외장 두 Space를 왕복했다. 두 알림의 current Space가 실제 전환과 일치했고, 복귀 뒤 name·local order도 그대로였다.

GO:

- 외장 regular Space의 non-empty name이 같은 프로세스 안의 재연결 3회에서 unique하게 대응한다.
- current Space와 화면 소속이 연속 두 snapshot에서 안정된다.
- Space 변경 알림 뒤 전체 snapshot 재조회로 활성 외장 Space를 유일하게 찾는다.
- stranded와 type `4`를 regular current Space로 오인하지 않는다.

STOP:

- name 소실·중복으로 같은 외장 Space를 유일하게 다시 찾지 못한다.
- 같은 조건 반복에서 Space 화면 소속이 달라진다.
- current Space 변경 완료를 bounded debounce와 two-read로 잡지 못한다.

결정: **GO**. 외장 regular Space identity는 name으로 유일하게 대응했고, global/local order는 저장 키에서 제외한다. 화면 재연결 뒤 membership을 쓰는 경로에는 1.5초 후행 대기와 two-read를 함께 적용한다.

### P2 — SpaceReader와 AX join

파일 범위:

- 새 파일 `Sources/PlugbackKit/SpaceReader.swift`
- 수정 `Sources/PlugbackKit/Model.swift`
- 수정 `Sources/PlugbackKit/WindowGateway.swift`
- 수정 `Sources/PlugbackKit/AXWindowGateway.swift`
- 수정 `docs/UNDOCUMENTED_APIS.md`

완료 조건:

- private symbol 부재와 dictionary 형식 변화가 `.unavailable`로 끝난다.
- raw ID와 name이 로그·ProfileStore·UserDefaults에 기록되지 않는다.
- 같은 AX 창이 정확히 한 Space에 join된다.
- type `4`와 fullscreen unknown이 이동 가능 창으로 내려가지 않는다.
- reader fake 하나로 interface 전체 정책을 테스트할 수 있다.

완료 기록(2026-08-27):

- `SpaceReader`는 필요한 read-only 심볼이 모두 있을 때만 동작하고, private dictionary 전체를 검증한 연속 두 snapshot이 다르면 `.unavailable`로 닫힌다. runtime ID·name·CGWindowID 모델은 `Codable`이 아니며 어떤 저장 경로에도 연결하지 않았다.
- `WindowInfo`에 마지막 열거 한정 `windowServerID`와 `windowed | fullscreen | unknown`을 추가했다. 기존 `isFullscreen` 호출과 flat 복원 테스트는 그대로 유지했다.
- 집중 테스트를 포함한 패키지 테스트 127개가 통과했다. 실물 probe에서는 일반 Space 상태의 AX 표준 창 `7/7`, 활성 Zed fullscreen 상태의 `5/5`가 각각 정확히 한 Space에 join됐다.
- 활성 Zed에서 Space type `4` 1개와 `AXFullScreen` 1개가 함께 검출됐다. 같은 type `4`가 비활성이면 topology만 남고 Zed AX 창은 열거되지 않았다.

결정: **완료**. reader는 아직 RestoreEngine에 주입하지 않았으므로 기존 제품 동작에는 변화가 없다. type `4`·fullscreen unknown의 이동 차단은 이 3상태와 kind를 소비하는 P3 planner에서 단일 정책으로 검증한다.

### P3 — slot-aligned overlay와 순수 planner

파일 범위:

- 수정 `Sources/PlugbackKit/ProfileSlots.swift`
- 수정 `Sources/PlugbackKit/CaptureEngine.swift`
- 수정 `Sources/PlugbackKit/RestoreEngine.swift`
- 테스트 `Tests/PlugbackKitTests/SpaceAwareRestoreTests.swift` 한 파일

완료 조건:

- profile과 overlay가 manual/auto/candidate 수명에서 원자적으로 움직인다.
- frame과 binding이 반드시 같은 창 선택 결과에서 만들어진다.
- inactive, duplicate, missing, stranded, type `4`, membership 0/2+가 모두 bundle 단위 건너뜀이다.
- overlay 없는 기존 profile은 기존 테스트 결과가 그대로다.
- 같은 bundle이 서로 다른 Space에 관찰되면 unresolved이며 좌표를 덮어쓰지 않는다.

완료 기록(2026-08-27):

- `CaptureEngine`의 Space-aware interface가 profile+overlay를 한 결과로 반환한다. 같은 bundle이 둘 이상의 Space에 있거나 join·name·type·fullscreen 판정이 불확실하면 binding만 unresolved로 만들고 저장 좌표는 유지한다.
- `ProfileSlots`는 manual/auto/candidate를 각각 profile+메모리 overlay pair 한 값으로 들고 capture·collect·confirm·seed·add·edit·remove 수명에서 함께 이동한다. 기존 JSON schema에는 필드를 추가하지 않았다.
- `RestoreEngine.selectSpaceWindow`는 `legacy | window | inactive | unavailable | fullscreen`만 반환한다. binding이 있으면 name으로 대상 Space를 찾고, 실패해도 기존 좌표 기반 창 선택으로 내려가지 않는다. local order hint는 판정에 쓰지 않는다.
- `SpaceAwareRestoreTests` 3개와 기존 회귀를 합친 130개 테스트, macOS 앱 빌드가 통과했다. duplicate/missing/stranded/type `4`, membership 0/2+, fullscreen true/unknown, 다중 Space bundle, slot pair 수명을 포함한다.

결정: **완료**. 아직 controller가 새 interface를 호출하지 않으므로 shipping 동작은 그대로다.

### P4 — 수동 vertical slice

파일 범위:

- 새 파일 `Sources/PlugbackKit/ActiveSpaceWatcher.swift`
- 수정 `Sources/PlugbackKit/PlugbackController.swift`
- 수정 `App/Plugback/AppServices.swift`
- 관련 controller 테스트

실험실이 켜진 Debug 앱에서만 실물 SpaceReader를 주입한다. 자동 슬롯의 수집 확대는 아직 하지 않는다.

시나리오:

1. 외장 Desktop 3에서 대상 앱 위치를 수동 저장
2. 외장 Desktop 4로 전환해 Finder·Zed 위치를 수동 저장
3. 외장 화면 분리·재연결
4. 현재 Space가 먼저 복원되는지 확인
5. Desktop 3·4를 차례로 방문해 각각 한 번만 복원되는지 확인
6. fullscreen Zed는 감지하되 움직이지 않는지 확인

GO:

- 내장 화면과 다른 외장 Space의 창이 움직이지 않는다.
- 활성화한 Space의 대상 앱만 기존 오차·재시도 규칙으로 복원된다.
- 알림 폭주나 복원 중 전환에도 창 ID가 무효화되지 않는다.

진행 기록(2026-08-27):

- `ActiveSpaceWatcher`가 공개 Space 변경 알림을 1.5초 후행 debounce로 압축하며, Debug reader와 실험실이 함께 켜진 동안만 구독한다. 실기기에서 0.15초에는 Mission Control 전환 중의 AX frame이 저장 좌표로 남아 `alreadyInPlace`로 오판했지만, 전환이 끝난 뒤 같은 수동 복원은 실제 frame 차이를 읽고 정상 이동했다.
- 수동 저장은 같은 AX 열거에서 frame과 Space binding을 함께 잡는다. 재연결 시 binding을 방문 대기로 만들고 현재 Space만 복원한 뒤, 나머지는 해당 Space 방문 이벤트까지 유지한다.
- Space-aware pass는 앞서 시작한 창 read를 drain하고, 새 창 polling 뒤 authoritative AX 열거 1회 → stable snapshot → planner → 같은 gateway ID로 move 순서를 지킨다. 완료·제자리·fullscreen만 방문 대기에서 제거한다.
- P4 동안에는 profile과 Space overlay가 다른 legacy 후보로 갈리는 것을 막기 위해 Space 실험 경로의 자동 수집을 멈춘다. 현재 Space binding을 함께 수집하는 일은 P5 범위다.
- controller vertical slice, fullscreen, reader unavailable legacy fallback, 창 read drain, 이벤트 압축을 검증했다. 후속 리뷰에서 Space 경로의 최소화 옵션과 수동 복원 모드의 현재 Space 한정 동작을 보강했으며, 두 회귀를 포함한 전체 137개 테스트와 서명된 Debug 앱 빌드가 통과했다.
- 2026-08-29 실기기 게이트에서 다른 외장 화면 B를 연결했을 때 AX 창 열거만 2회 발생하고 이동은 0회여서 저장된 A 화면 배치가 B에 적용되지 않았다.
- A 재연결 뒤 저장된 다른 regular Space를 교란하고 방문하자 1.5초 후 Finder와 Zed가 각각 한 번씩 복원됐다. 같은 Space를 다시 교란해 재방문했을 때는 AX 재열거와 이동이 모두 늘지 않아 방문 대기의 Space별 1회 수명이 확인됐다.
- 활성 Buzz native fullscreen에서 reader는 type `4` 1개, `AXFullScreen=true` 1개, 표준 창 `5/5`의 단일 Space join을 보고했다. 메인 프로세스의 누적 이동은 2회로 유지돼 연결된 상태의 fullscreen 방문에서는 창을 움직이지 않았다.

P4 당시 남은 게이트였던 “fullscreen 감지만 하고 이동 0회”는 2026-08-29의 제품 결정으로 대체됐다. P5부터는 확인된 single fullscreen을 수집·재생성하고, Split View와 불명확한 type `4`만 그대로 둔다. 위 P4 기록은 당시 빌드의 실기기 결과로 보존한다.

### P5 — 자동 슬롯 수집 통합

기존 `CollectTrigger`와 `ProfileSlots`에 현재 활성 Space binding을 함께 전달한다.

- 자동 슬롯이 켜진 동안에만 이동 정착, Space 방문, Mission Control 닫힘을 수집 신호로 사용한다. 끄면 observer를 멈추고 미확정 후보를 폐기한다.
- Space 활성화 직후 방문 대기 복원이 있으면 복원 후에만 수집한다.
- 평상시 방문이면 현재 Space에서 확인된 모든 표준 창을 후보에 등록·갱신한다. 체크 해제 앱과 방문 대기 앱은 제외한다.
- 실행 중인 non-minimized 창이 다른 화면에만 있고 대상 외장 화면에는 하나도 없으면 해당 앱과 binding을 자동 후보에서 제거한다. 수동 슬롯과 이동 observer 명부는 남겨 다시 외장 화면으로 돌아오면 재등록할 수 있게 한다. 종료·최소화·방문 대기 상태만으로는 제거하지 않는다.
- single native fullscreen도 처음 본 앱이면 등록한다. 기존 일반 frame은 유지하고, 처음 본 앱은 화면 bounds를 staging frame으로 쓰며 fullscreen 의도는 overlay에 기록한다.
- 비활성 type `4`는 AX 표준 창이 없어도, 공개 CG window metadata에서 `layer=0`, `alpha>0`, 화면 전체 bounds인 regular 앱 창이 그 Space에 정확히 하나 join될 때만 수집한다. 같은 앱의 후보가 한 화면에 둘이거나 Split View처럼 화면 전체가 아니면 기록하지 않는다.
- 화면 분리와 앱 종료 확정은 창을 다시 읽지 않고 profile+overlay 후보를 함께 기록한다.
- manual/auto 중 더 최근 슬롯이 이길 때 overlay도 같은 슬롯에서 온다.
- fullscreen 복원은 실행 중인 표준 창 하나에만 적용한다. 다른 화면에서 이미 fullscreen이면 해제하고, 저장된 일반 frame으로 목표 외장 화면에 옮긴 뒤 다시 진입한다.
- fullscreen 전환 뒤에는 다음 stable snapshot에서 목표 화면의 single type `4`를 확인해야 방문 대기를 제거한다.

GO:

- 사용자가 각 Space를 평소처럼 방문·배치한 뒤 분리하면, 재연결 후 방문 순서와 무관하게 각 Space가 자기 위치로 돌아온다.
- single fullscreen 대상이 내장 화면으로 밀려도 목표 외장 화면에서 다시 fullscreen이 된다.
- 실험실을 끄면 observer와 private read가 모두 멈추고 자동 수집 후보가 폐기된다. 수동 저장·기존 복원은 유지된다.

구현 기록(2026-08-29):

- `ActiveSpaceWatcher` 방문과 기존 `CollectTrigger` 이동 정착이 같은 Space-aware 후보 수집 경로를 쓴다. 방문 대기 bundle은 수집에서 제외해 실패한 복원 위치가 저장값을 덮지 않는다.
- Space-aware 수집·복원은 현재 type `4`의 비대상 표준 창까지 한 번 열거해 single fullscreen과 Split View를 구분한다. 수집은 방문한 현재 Space의 처음 본 bundle도 후보에 넣고, 복원은 선택된 profile bundle만 움직인다.
- 시작·자동 저장 ON 전환·기존 수집 신호마다 모든 type `4`를 함께 읽는다. 비활성 fullscreen은 불투명 layer `0` 창 하나가 해당 화면 bounds와 일치할 때만 보충하므로 Space 방문이 필요 없다. 자동 저장 OFF에서는 이 경로 자체가 실행되지 않는다.
- `SpaceBinding.fullscreen`은 메모리 overlay에만 존재한다. raw Space ID·CGWindowID·Mission Control 순서는 저장하지 않는다.
- `AXWindowGateway`는 raw `AXFullScreen`의 settable 여부를 확인하고 상태 변경을 최대 8초 폴링한다. fullscreen Space를 직접 이동하는 SkyLight write는 쓰지 않는다.
- 일반 방문의 새 앱 자동 등록, 자동 슬롯 OFF 게이트, 처음 본 single fullscreen 수집, Split View 제외, 내장 fullscreen 해제→외장 이동→재진입→stable type `4` 확인을 포함한 전체 146개 테스트가 통과했다.
- 외장 fullscreen으로 저장했던 Buzz를 windowed 상태로 내장 화면에 옮긴 뒤에도 예전 `.fullscreen` binding이 후보에 남는 회귀를 확인했다. 대상 외장 화면에서 명확히 떠난 앱을 자동 후보에서 제거하는 테스트를 추가했고, A 자동 프로필에는 Zed가 남고 Buzz가 빠진 것을 실제 저장 파일에서 확인했다.
- A에서 수집한 Zed fullscreen은 B 연결 때 자동으로 B로 이동하지 않았다. 사용자가 B에서도 Zed fullscreen을 방문한 뒤 B를 분리하고 A를 연결하자 Zed type `4`는 내장 화면에 비활성으로 남았다. 이를 방문하자 Plugback이 fullscreen 해제 → A 이동 → fullscreen 재진입을 수행했고, 기존 내장 type `4`가 사라진 뒤 A에 새 type `4`가 생겼다. Buzz는 `fullscreen=false`인 채 내장 화면에 남았다.
- A의 Zed type `4`를 비활성으로 둔 채 raw 후보 probe를 실행했다. 화면 전체인 불투명 본창 하나만 A 후보로 잡혔고, 같은 Space의 높이 44px·alpha `0` 보조창과 내장 regular Zed 창은 제외됐다. 이 후보가 내장 regular 관찰보다 우선해 `.fullscreen` overlay로 수집되는 회귀 테스트도 통과했다.
- Zed fullscreen을 방문하지 않은 채 A를 분리하자 카드의 미확정 후보가 21:26:31 자동 슬롯에 확정됐다. B 연결 중에는 Zed 본 fullscreen이 내장 화면에 남아 A 프로필이 B에 적용되지 않았다. A 재연결 때 macOS가 type `4`를 스스로 A에 다시 붙인 회차는 Plugback 성공 횟수에서 제외했다. 이후 Mission Control로 같은 비활성 type `4`를 내장 화면에 옮기고 방문만 하자, 기존 내장 SID `606`이 사라지고 A에 새 SID `628`이 생겼으며 같은 Zed 창이 A 전체 bounds로 이동했다. 이를 한 번 더 반복해 내장 SID `628`이 사라지고 A에 새 SID `640`과 같은 전체 bounds 창이 생긴 것도 확인했다. 방문 없는 수집에서 시작한 fullscreen 복원 실기기 게이트는 3/3이다.
- 이 fullscreen 회차 직전 Debug 앱 재시작으로 regular overlay가 사라졌으므로, 같은 회차의 비활성 regular Space 미복원은 P5.5 성공 횟수에 포함하지 않는다.

남은 실기기 게이트:

1. 자동 슬롯 ON에서 두 regular Space를 방문·교란하고 분리해 후보가 함께 확정되는지 확인
2. 자동 슬롯 OFF에서 같은 방문·교란이 후보 시각과 저장값을 바꾸지 않는지 확인
3. 방문하지 않은 처음 본 앱의 single fullscreen 자동 수집 뒤 A → B → A
4. Split View 방문·재연결에서는 fullscreen write와 창 이동이 0회인지 확인

### P5.5 — regular Space 화면 소속 복구

A → B → A에서 저장된 다른 regular Space와 두 native fullscreen Space가 내장 화면에 남아, 창 단위 복원만으로는 외장 화면의 Space 구성을 되돌릴 수 없는 상태를 실기기에서 확인했다.

실측·구현 기록(2026-08-29):

- 사용자가 Mission Control에서 내장 화면의 저장된 regular thumbnail 하나를 A로 drag하자 같은 runtime SID와 opaque name이 유지됐고, Buzz/Zed type `4` 두 개도 A로 돌아왔다. Finder frame과 두 fullscreen 상태가 유지됐으며 Plugback의 AX window move/fullscreen write는 0회였다.
- Dock AX tree는 화면별 `mc.display`/`AXDisplayID`, `mc.spaces.list`, 각 thumbnail frame을 노출했다. 내장 화면에 만든 빈 비활성 regular Space를 합성 drag로 A 끝에 보냈다가 되돌리는 왕복을 3/3 수행했다.
- 매 편도에서 같은 SID·name·kind가 유지되고 다른 regular Space의 소속·상대 순서, current Space, 관찰한 window membership이 불변이었다. source/destination AX child count도 snapshot과 일치했다.
- `SpaceRelocationPlanner`는 저장된 regular name이 다른 화면에 unique하게 남고 비활성이며 source의 마지막 regular가 아닐 때만 이동을 만든다. 이 단계에서는 `MissionControlSpaceRelocator`를 Debug에서만 주입했고, P5.8부터 Release에도 주입한다. pointer 입력 뒤에는 새 stable snapshot을 검증한다.
- 합성 실패·AX tree 불일치·snapshot 불안정·예기치 않은 regular 이동은 즉시 중단한다. SkyLight write, raw create/destroy, 자동 rollback은 없다. 실패해도 기존 현재 Space/방문 기반 창 복원은 계속된다.
- fullscreen Space는 직접 선택하지 않는다. regular 이동에 따라 macOS가 함께 옮긴 경우 동일 runtime Space 집합과 membership을 검증하고 받아들인다. 따라오지 않으면 기존 single fullscreen 재생성 경로가 담당한다.
- 첫 A 재연결 실패는 source/destination child count까지 통과한 뒤 thumbnail action guard에서 끝났다. 이동 대상 외의 현재·마지막 Space에는 `AXRemoveDesktop`이 없을 수 있는데 양쪽 모든 child에 이 action을 요구한 것이 원인이었다. 대상 child 하나만 확인하도록 줄였다.
- 수정본에서 저장된 Finder regular Space를 A에서 내장 화면으로 직접 옮긴 뒤 수동 복원을 실행하자 Mission Control visible drag가 동작했다. 같은 opaque name의 Space가 A local order 2로 돌아왔고 Finder layout도 복원됐으며, stable probe가 A의 regular order 1·2를 확인했다.
- B에서 해당 Space를 건드리지 않은 A → B → A 회차는 macOS가 스스로 A에 다시 붙여 relocation 경로를 실행하지 않았다. 이 회차는 회귀 없음만 확인했고 자동 relocation 성공 횟수에는 세지 않는다.
- 전체 146개 테스트와 수정 뒤 `SpaceAwareRestoreTests` 18개, 서명 Debug 빌드가 통과했다.

남은 실기기 게이트:

1. A → B에서 실제 사용처럼 창을 재배치해 저장된 비활성 regular Space가 settling 뒤에도 내장 화면에 남는 회차를 만들고, A 재연결 자동 복구를 3/3 확인
2. Buzz/Zed type `4`가 그대로 따라왔는지, 따라오지 않았으면 방문 기반 재생성만 일어나는지 확인
3. 다른 regular Space 이동 0회, AX child/snapshot 불일치 시 무동작 확인

### P5.6 — 앱과 무관한 regular Space 화면 소속 수집

앱 binding이 있는 Space만 기억하던 제한을 없애고, 같은 snapshot에서 외장 화면의 식별 가능한 regular Space 전체를 별도 목록으로 수집한다.

실측·구현 기록(2026-08-29):

- 새 비활성 Space를 내장 → A → 내장 → A로 방문 없이 왕복했다. 같은 runtime SID와 opaque name이 유지돼 Space 자체의 화면 소속을 앱 없이 대응할 수 있음을 확인했다.
- 비활성 drag에는 `NSWorkspace.activeSpaceDidChangeNotification`, 앱 활성·비활성, 알려진 expose distributed/Darwin notify가 오지 않았다.
- Dock application AX observer에서는 사용자가 연 Mission Control 두 회차 모두 `AXUIElementDestroyed`가 닫힐 때 정확히 한 번 왔다. `mc` tree를 실제로 본 회차만 closed로 인정해 다른 Dock 요소 삭제를 수집 신호로 낮추지 않는다.
- `SlotSpaceOverlay.regularSpaces`는 unique non-empty opaque name과 당시 local order만 메모리에 둔다. raw SID는 저장하지 않고 앱 목록 편집에도 지워지지 않는다.
- 수동 저장과 자동 수집 모두 같은 stable snapshot의 전체 regular 목록을 담는다. 자동 수집은 자동 슬롯 ON에서 Mission Control 닫힘 뒤 한 번 더 실행되며, OFF이면 observer와 candidate가 모두 꺼진다.
- `SpaceRelocationPlanner`는 앱 binding과 독립 목록의 합집합을 사용한다. 따라서 profile app이 0개인 regular Space도 기존 visible drag와 전후 snapshot 검증 경로를 그대로 탄다.
- 한 desired Space가 현재·소실 등으로 막혀도 뒤의 안전한 비활성 Space 이동을 계속 고르도록 planner를 보강했다. 첫 blocked 항목 하나가 전체 복구를 가리는 회귀 테스트를 포함한다.
- 빈 Space 수집→확정→재배치 plan, 이름 없음 제외, Mission Control open/closed burst 압축을 포함한 전체 150개 테스트가 통과했다.
- `labRegularSpaceRestore`를 별도 저장 설정으로 두고 controller의 visible drag와 Space별 창 복원을 함께 게이트한다. 기존 `labSpaceRelocation` defaults key는 유지한다. 새 값이 없는 기존 자동 슬롯 사용자는 최초에 그 값을 이어받고, OFF 회귀 테스트는 relocator 호출이 늘지 않음을 확인한다.
- 실제 앱에서 A의 regular Space 세 개를 후보로 모은 뒤, 가운데 Space를 A→내장으로 옮기고 Mission Control을 닫자 후보가 3→2로 바뀌었다. 다른 내장 Space를 A로 옮기자 2→3이 되면서 이전 identity가 아니라 새 opaque name이 들어왔다. slot 수 추측이 아니라 Space identity와 화면 소속을 다시 읽은 결과다.
- A 분리 시 이 세 opaque name이 자동 슬롯에 확정됐다. B에는 A 프로필을 적용하지 않았고, B 분리 뒤 A를 연결하자 저장된 비활성 Space 두 개는 macOS가 같은 SID·name으로 A에 스스로 다시 붙였다. relocation 중단점은 0회였고, A 대상이 아니었던 별도 Space는 내장 화면에 남았다.
- 경로를 강제로 검증하려고 A에서 다시 저장한 뒤 저장 대상 비활성 Space 하나를 내장 화면으로 옮기고 수동 복원을 실행했다. planner와 relocator가 각각 1회 실행됐고 Mission Control visible drag 뒤 같은 SID `dbc7…`·opaque name `2f5f…`이 A local order 3으로 돌아왔다. 다른 내장 Space는 움직이지 않았고 복원 후 두 read의 topology·membership이 동일했다.
- 실제 사용 회차에서는 B 자동 후보에 regular Space 두 개와 Fork single fullscreen이 기록됐다. B 분리 뒤 A 대상 regular Space 두 개와 B의 type `4`가 내장 화면에 남았고, A 재연결 때 planner move와 사후 검증이 각각 1회 실행됐다. 최종적으로 A에는 저장된 regular Space 세 개가 돌아왔고 B 전용 Fork type `4`는 내장 화면에 남았다. 자동 재연결 relocation은 1/3 통과다.

남은 실기기 게이트:

1. macOS가 저장 Space를 스스로 A에 다시 붙이지 않는 A → B → A 회차에서 자동 relocation을 2회 더 확인해 합계 3/3 만들기
2. 자동 슬롯 OFF에서는 같은 Mission Control drag가 후보와 저장값을 바꾸지 않는지 확인

### P5.7 — 저장 방식과 복원 범위 분리

사용자 설정을 세 독립 축으로 정리한다.

- 「자동 슬롯」은 이동·방문·Mission Control 닫힘 수집과 분리/종료 확정만 제어한다.
- 「일반 Space 복원」은 Space 자체의 화면 복구와 Space별 창 위치 복원을 함께 제어한다.
- 「전체 화면 복원」은 확인된 single native fullscreen 재생성만 제어한다.
- 수동 저장은 자동 슬롯 OFF에서도 일반 Space 또는 전체 화면 복원이 ON이면 manual overlay를 함께 잡는다. 두 복원 토글은 manual/auto 중 선택된 슬롯에 같은 방식으로 적용된다.
- 복원 범위가 OFF인 binding은 legacy 창 복원으로 내려가며 raw fullscreen write나 Mission Control drag를 실행하지 않는다.
- 이전 「일반 Space 자체 복원」 값과 기존 자동 슬롯 사용자의 fullscreen 동작은 각각 한 번 이어받고, 이후 세 값은 독립적으로 저장한다.

자동 슬롯 OFF에서 수동 슬롯만으로 regular Space를 외장 화면에 되돌린 뒤 방문한 창 위치를 복원하는 회귀 테스트와, single fullscreen 재생성·별도 OFF 시 fullscreen write 0회 회귀 테스트를 추가했다.

### P5.8 — Release 실험실 노출

- `AppServices`가 Release에도 `SpaceReader`와 `MissionControlSpaceRelocator`를 주입하고 설정의 세 실험실 토글을 표시한다.
- 세 토글이 모두 OFF이면 private Space snapshot을 읽지 않고 기존 flat 저장·복원 경로만 쓴다.
- 기능은 Release에 포함되지만 기본 꺼짐인 실험실 상태를 유지한다.

### P5.9 — 자동 슬롯 반영 방식

- 실험실의 자동 슬롯 아래에서 「분리할 때 저장」(기본), 「변경 즉시 저장」, 「복원 즉시 반영 · 분리 시 저장」을 고른다.
- 세 방식은 같은 화면별 candidate와 auto slot을 공유한다. 저장 시점과 연결 중 후보를 복원 소스로 쓸지만 달라지므로 A/B 프로필 격리는 유지된다.
- 기존 설정에는 새 값이 없으므로 현재 동작인 「분리할 때 저장」으로 이어간다. 「변경 즉시 저장」으로 바꾸면 이미 대기 중인 후보도 곧바로 확정한다.
- 「복원 즉시 반영 · 분리 시 저장」의 카드는 저장된 자동 슬롯과 혼동하지 않도록 `복원 소스 · 현재 배치 · 저장 대기`로 표시한다.

### P6 — 결과 표시와 현재 문서 동기화

실기기 vertical slice가 통과한 뒤에도 예측 어휘는 늘리지 않는다. 방문 대기·Space 판정 불가는 이번 복원 회차의 결과가 아니므로 점을 만들지 않고 Space 그룹 상태가 이유를 설명한다.

- legacy와 Space-aware 복원 예측이 같은 선택 결과를 쓰게 한다
- 카드의 Space별 예측 보정을 삭제한다
- `CONTEXT.md`, `FUNCTIONAL_SPEC.md`, `ARCHITECTURE.md`, `RESTORE_FLOW.md`, `UNDOCUMENTED_APIS.md` 갱신
- 필요하면 `US-014-active-space-restore.md` 추가

진행 기록(2026-08-30): 같은 선택 결과를 쓰도록 통합하고 카드 보정을 삭제했다. 후속 아키텍처 검토에서 별도 legacy 복원 진입점과 앱별 재열거를 삭제해 RestoreSession의 한 복원 회차로 합쳤고, ProfileSlots의 저장값·후보를 profile+overlay pair로 바꿨으며, 수집의 화면 이탈·비활성 fullscreen 정책을 CaptureEngine에 모았다. 카드의 네 병렬 파생 사전은 화면별 projection 한 값으로 줄였다. 관련 기존 문서와 US-006을 갱신했으며, 새 사용자 스토리는 기존 F-08·US-006으로 계약이 충분해 만들지 않았다.

이 기능은 Release에도 기본 꺼짐인 실험실로 노출한다. 정식 동작으로 승격하기 전에는 아래 호환성·실기기 게이트를 계속 적용한다.

진행 기록(2026-08-29, 사용자 확인용 Debug surface):

- 카드의 평면 앱 목록을 저장된 일반 Space별로 묶고, 한 외장 화면 안의 저장 순서대로 `Space N`을 붙인다. macOS의 전역 `데스크탑 N`을 흉내 내지 않으며 overlay identity나 저장값으로 쓰지 않는다.
- 카드 행은 live inventory가 아니라 저장된 복원 계획이다. snapshot이 없거나 name 대응이 유일하지 않아도 저장된 로컬 순번을 유지하고 상태만 숨긴다. unique 대응이면 `현재`, `방문 시 복원`, `다른 화면 · 복원 대기`, `현재 없음`을 구분하며 live-but-unsaved Space는 행으로 섞지 않는다.
- 앱이 없는 저장 regular Space도 `저장된 앱 없음`으로 보인다. 비활성·판정 불가 Space에는 복원 결과와 예측 점을 만들지 않고 그룹 상태로 이유를 설명한다. 목표 화면의 현재 regular Space 구성과 저장본이 다르면 자동 슬롯은 분리 시 확정될 변경으로, 수동 슬롯은 저장 버튼으로 갱신할 변경으로 알린다. single fullscreen은 `전체 화면`, 불명 binding은 `Space 확인 필요`로 분리한다.
- core의 로컬 순번 테스트와 앱 표현 테스트를 추가했다. 최종 제품 surface 확정과 P6 전체 문서 승격은 남은 relocation 실기기 게이트 뒤에 한다.

### P7 — 영속화 여부: 별도 결정

이 브랜치의 필수 범위가 아니다. 다음을 모두 3회 통과한 뒤 새 계획으로 다룬다.

- 앱 재시작
- 로그아웃·로그인
- 재부팅
- Space 삭제 후 새로 생성
- 같은 화면의 포트·도크 변경

통과하더라도 raw name 대신 안정 digest를 저장할지, `TargetApp`을 `(bundle, SpaceHint)` placement 배열로 바꿀지 별도 schema 결정을 한다. 실패하면 same-process 메모리 overlay를 제품 상한으로 유지한다.

## 9. 최소 테스트 표

새 테스트 파일 하나에 표 기반 케이스를 모은다.

- global Desktop 번호가 밀려도 unique name으로 같은 외장 Space resolve
- inactive binding은 이동하지 않고 활성화 때만 이동
- name 소실·중복, 다른 화면, membership 0/2+는 해당 bundle만 건너뜀
- regular binding의 fullscreen true와 fullscreen unknown은 이동하지 않음
- single fullscreen 의도는 일반 frame을 유지하고 overlay에만 수집
- 처음 본 일반 앱과 single fullscreen 앱도 자동 슬롯 후보에 등록
- 앱이 없는 unique regular Space도 자동 후보와 relocation plan에 유지
- Mission Control open→closed 이벤트 폭주는 수집 1회로 압축하고 OFF에서는 observer 제거
- Split View·다중 창 type `4`는 fullscreen 의도로 낮추지 않음
- 다른 화면의 single fullscreen은 해제 → 목표 frame 이동 → 재진입
- AX fullscreen 전환 뒤 stable target type `4` 확인 전에는 방문 대기 유지
- 자동 슬롯 OFF에서는 Space 방문과 이동 정착이 후보를 만들지 않음
- 같은 화면의 확실한 다른 bundle은 계속 복원
- Space-bound bundle은 legacy로 재선택되지 않음
- 다른 화면의 비활성 regular binding만 Space relocation 대상으로 선택
- current·마지막 regular·name 중복/소실·AX child count 불일치에서는 visible drag 0회
- regular relocation 전후 동일 SID·kind·name·membership과 다른 regular 소속·상대 순서 검증
- regular를 따라 이동한 type `4`는 허용하되 직접 type `4`를 drag하지 않음
- overlay 없는 profile은 기존 `pickWindow` 유지
- manual/auto/candidate source와 overlay가 같은 쌍으로 선택됨
- capture/collect/confirm/seed/add/edit/remove의 overlay 수명
- authoritative enumeration 뒤 move 종료까지 재열거 0회
- 복원 전 진행 중 window read drain
- 복원 중 Space 이벤트는 끝난 뒤 한 번만 재처리
- 실험실 off 또는 reader unavailable에서 기존 회귀 테스트 결과 동일

자동 확인:

```sh
swift test
xcodebuild test -project App/Plugback.xcodeproj -scheme Plugback \
  -destination 'platform=macOS' -derivedDataPath build
```

실기기 확인은 P1·P4·P5의 행렬을 별도로 기록한다. private API 생존 여부는 unit test가 증명할 수 없다.

## 10. 보류한 대안

| 대안 | 보류 이유 | 다시 볼 조건 |
|---|---|---|
| 키보드로 모든 Space 자동 순회 | 포커스·애니메이션·사용자 단축키·대상 화면에 의존 | 방문 기반 UX가 사용자 검증에서 실패할 때 별도 실험 |
| Mission Control UI 자동화 | **Release의 기본 꺼짐 실험실에서 regular relocation preflight로 채택.** 화면에 보이고 UI 변경에 취약하므로 strict AX/snapshot gate 뒤 한 번만 수행 | OS 업데이트 때 실기기 재게이트 |
| SkyLight private write | OS 버전·보안 설정 의존, 잘못된 Space 이동 위험 | 배포 기능이 아닌 별도 연구 브랜치에서만 |
| raw CGWindow bounds로 비활성 창 직접 복원 | 자동 수집의 보수적 fullscreen 판정에만 채택. 이동할 AX 표준 창은 여전히 없어 직접 복원·검증 불가 | 안정적인 CG→AX 역방향 join이 검증될 때 |
| Split View 자동 생성 | pairing·side·divider를 보장하는 수단 없음 | Apple 공개 capability가 생길 때 |
| fullscreen Space 순서 복원 | 공개된 순서 변경 수단이 없고 자동 재정렬 설정에 좌우됨 | creation-order 실측과 별도 사용자 옵션이 필요할 때 |

## 11. 이 브랜치의 완료 정의

`feature/active-space-restore`는 P1–P6을 통과하면 완료다.

- 실험실이 꺼진 기본 동작에 회귀가 없다.
- 같은 프로세스 안에서 외장 화면 분리·재연결 후, 식별 가능한 regular Space 자체를 목표 외장 화면으로 되돌리고 방문한 Space의 대상 앱만 복원한다.
- 저장된 비활성 regular Space가 다른 화면에 unique하게 남은 경우에만 실험실 visible drag로 목표 외장 화면에 되돌리고, 그 밖의 내장 배치는 자동 조작하지 않는다.
- 확인된 single fullscreen만 목표 외장 화면에서 best-effort로 재생성한다. Split View·다중 창·순서는 건드리지 않는다.
- private read 실패는 crash나 잘못된 이동이 아니라 bundle 단위 건너뜀 또는 기존 동작으로 끝난다.
- 코드, 기능명세, architecture, 복원 흐름, 비공식 API 목록이 같은 경계를 설명한다.
