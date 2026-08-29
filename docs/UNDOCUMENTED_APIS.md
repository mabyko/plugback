# 비공식 API 사용 목록

## Plugback

> **문서 관계**
> - [ARCHITECTURE.md](./ARCHITECTURE.md) — 이 이름들을 쓰는 모듈의 경계.
> - [FUNCTIONAL_SPEC.md](./FUNCTIONAL_SPEC.md) — 이 이름들이 만족시키는 동작 (F-01.3).
>
> 이 앱이 **SDK 헤더에 선언되지 않은 이름**에 기대는 곳은 여기가 전부다.
> 새로 하나 쓰려면 이 문서에 줄이 하나 늘어야 한다. 줄이 늘지 않으면 쓰지 않은 것이다.

---

## 원칙

1. **깨져도 조용히 꺼진다.** 이름이 사라지거나 뜻이 바뀌면 그 기능만 이전 동작으로 돌아간다. 크래시도, 잘못된 복원도 없다. 이 조건을 만족하지 못하는 비공식 이름은 쓰지 않는다.
2. **판정은 주입 가능하다.** 실물 구현은 어댑터 한 곳에만 있고, 테스트는 스텁을 넣는다. 이름이 바뀌면 고칠 자리가 한 곳이다.
3. **공개 대체재가 있으면 그것을 쓴다.** 아래 항목은 공개 대체재가 없어서 남았다. 대안은 각 항목에 적어둔다.

---

## 1. `CGSSessionScreenIsLocked` — 화면 잠금 여부

| | |
|---|---|
| **쓰는 곳** | `DisplayWatcher.screenIsLocked()` |
| **무엇을 판정** | 지금 화면이 잠겨 있나 (잠금 미루기, F-01.3) |
| **공개 여부** | 함수 `CGSessionCopyCurrentDictionary()`는 **공개** — `CGSession.h`, macOS 10.3+. **키는 헤더에 없다.** |

헤더가 선언한 세션 키는 다섯뿐이다 — `UserID` · `UserName` · `ConsoleSet` · `OnConsole` · `LoginDone`. 잠금 키는 그중에 없다. 확인:

```sh
grep -n "kCGSession" "$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreGraphics.framework/Headers/CGSession.h"
```

**깨지면 무슨 일이 나나** — 키가 없거나 이름이 바뀌면 조회 결과가 `nil`이고, 판정은 「잠기지 않음」이 된다. 잠금 미루기만 꺼지고 억제 창 안에서 온 연결은 다시 유실된다(이 기능을 넣기 전 동작). 사용자에게는 「가끔 복원이 안 된다」로 보이고, 수동 복원으로 잡을 수 있다.

**공개 대체재** — 없다. `NSWorkspace`에 잠금 상태를 묻는 API가 없다.

---

## 2. `com.apple.screenIsUnlocked` — 잠금 해제 알림

| | |
|---|---|
| **쓰는 곳** | `DisplayWatcher.start()` — `DistributedNotificationCenter` 구독 |
| **무엇을 트리거** | 미뤄둔 등장 회차 1건의 소비 (F-01.3) |
| **공개 여부** | **어느 헤더에도 없다.** loginwindow가 오래전부터 쏘는 이름이다 |

**깨지면 무슨 일이 나나** — 알림이 오지 않으면 미뤄둔 회차가 그 자리에 남는다. 다음 화면 파라미터 변경 이벤트가 오면 그때 소비된다. 잠금을 풀 때는 화면이 다시 켜지면서 그 이벤트가 함께 오는 경우가 많으므로, **이 알림은 그것이 오지 않을 때를 위한 보험에 가깝다.** 둘 다 오지 않으면 다음 진짜 연결이나 수동 복원까지 미뤄진다.

**공개 대체재** — 없다. 후보를 다 봤지만 뜻이 다르다.

- `NSWorkspace.sessionDidBecomeActiveNotification` — 빠른 사용자 전환용. 잠금 해제에는 오지 않는다.
- `NSWorkspace.screensDidWakeNotification` — 화면이 깨어난 것이지 잠금이 풀린 것이 아니다.
- `NSApplication.didBecomeActiveNotification` — 메뉴바 앱은 활성화되지 않는다.

---

## 3. `AXFullScreen` — 다른 앱 창의 native fullscreen 상태

| | |
|---|---|
| **쓰는 곳** | `AXWindowGateway.standardWindows()`, `AXWindowGateway.setFullscreen()` |
| **무엇을 판정·변경** | 대상 앱 표준 창의 native fullscreen 상태를 읽고, 확인된 single fullscreen 복원에서만 상태를 변경 |
| **공개 여부** | 현재 SDK의 공개 AX attribute 상수에 없는 raw 문자열이다 |

**깨졌을 때의 동작** — 읽기 attribute 부재·타임아웃·타입 불일치는 `unknown`이 된다. 기존 flat 경로의 `isFullscreen` 호환값은 종전처럼 `false`지만, Space-aware 경로는 3상태 값을 직접 보고 `unknown` 창을 움직이지 않는다. 쓰기 attribute가 settable이 아니거나 값 설정·8초 안의 상태 확인이 실패하면 fullscreen 복원 결과를 실패로 남기고 pending을 유지한다. raw 값 변경만으로 성공 처리하지 않으며, 다음 stable Space snapshot에서 목표 화면의 단일 type `4` membership까지 확인해야 완료한다.

**공개 대체재** — 다른 앱의 현재 native fullscreen 상태를 직접 주는 공개 AX attribute는 확인되지 않았다. 공개 `kAXFullScreenButtonAttribute` 요소에 `AXPress`를 수행하는 대안은 있지만, 버튼 존재는 현재 상태가 아니고 앱별 동작과 목표 화면을 보장하지 않는다. 현재 Debug/실험실 경로는 상태를 명시할 수 있는 raw attribute 한 경로만 검증한다.

---

## 4. `_AXUIElementGetWindow` — AX 창과 WindowServer 창의 임시 join

| | |
|---|---|
| **쓰는 곳** | `AXWindowGateway.standardWindows()` |
| **무엇을 판정** | 마지막 AX 열거의 표준 창이 어느 Space membership에 속하는가 |
| **공개 여부** | 현재 SDK 헤더에 선언되지 않은 ApplicationServices/HIServices 심볼이다 |

**깨졌을 때의 동작** — `dlsym` 실패나 개별 join 실패는 `WindowInfo.windowServerID == nil`이 된다. 기존 flat 복원은 그대로 동작하고, Space binding 경로는 그 창을 unresolved로 건너뛴다. ID는 저장하거나 로그에 남기지 않는다.

**공개 대체재** — 다른 앱의 AX 창에서 CGWindowID를 얻는 공개 API는 확인되지 않았다.

---

## 5. SkyLight read-only Space snapshot

| 이름 | 읽는 것 |
|---|---|
| `SLSMainConnectionID` | 현재 WindowServer 연결 ID |
| `SLSCopyManagedDisplaySpaces` | 화면별 Space topology |
| `SLSCopySpacesForWindows` | 임시 CGWindowID의 Space membership |
| `SLSSpaceGetType` | 일반 Space `0`과 fullscreen/Split View Space `4` 구분 |
| `SLSSpaceCopyName` | 같은 세션에서 Space를 대응할 opaque name |
| `SLSManagedDisplayGetCurrentSpace` | 화면별 현재 활성 Space |

**쓰는 곳** — `SpaceReader`. 모두 조회만 하며 Space·창을 변경하는 SkyLight 함수는 로드하지 않는다. 비활성 type `4`는 공개 `CGWindowListCopyWindowInfo`의 owner PID·layer·alpha·bounds를 membership과 합친다. regular 앱의 불투명 layer `0` 창이 해당 화면 전체를 채우고 그 Space에 정확히 하나일 때만 자동 수집 후보가 된다. 반쪽 bounds인 Split View, 투명 보조창, 복수 후보는 버린다.

**깨졌을 때의 동작** — 심볼 하나라도 없거나 dictionary 형식·화면 ID·현재 Space가 예상과 다르거나 연속 두 snapshot이 다르면 `.unavailable`이다. CG window metadata가 없거나 두 read 사이 후보가 달라도 잘못 낮추지 않고 snapshot 또는 후보를 버린다. 기존 flat 복원은 그대로이고 Space-aware 경로만 꺼진다. raw Space ID·CGWindowID는 메모리 밖으로 나가지 않는다.

**공개 대체재** — 화면별 Space topology·type·membership을 함께 제공하는 공개 API는 없다.

---

## 6. Mission Control Dock AX tree — 자동 수집과 DEBUG regular Space relocation

| 이름 | 쓰는 것 |
|---|---|
| `mc` | Mission Control이 이미 열려 있는지 확인 |
| `mc.display` | 화면별 AX group 찾기 |
| `AXDisplayID` | AX group을 현재 `CGDirectDisplayID`와 대응 |
| `mc.spaces.list` | 화면별 Space thumbnail 순서와 frame 읽기 |
| `AXRemoveDesktop` | 이동 대상으로 고른 child가 실제로 제거 가능한 Space thumbnail인지 확인 |
| `AXSelectedChildrenChanged`, `AXUIElementDestroyed` | `mc` tree를 본 Mission Control 회차가 닫힌 시점 감지 |

**쓰는 곳** — `MissionControlWatcher`, `MissionControlSpaceRelocator`. watcher는 자동 슬롯이 켜진 동안 `CollectTrigger` 안에서 Mission Control 닫힘을 수집 1회로 압축한다. relocator는 `AppServices`가 Debug 빌드에서만 주입하고, 별도 「일반 Space 자체 복원」 토글이 ON일 때만 호출한다. Space 생성·삭제 action을 실행하지 않고 stable snapshot이 고른 비활성 regular thumbnail 하나에 공개 `CGEvent` mouse drag를 합성한다. 두 notification 이름 자체는 공개 AX 상수지만 Dock의 `mc` identifier와 tree 수명은 공개 계약이 아니다.

**깨졌을 때의 동작** — watcher가 `mc` tree를 보지 못하거나 닫힘 notification이 오지 않으면 Mission Control 직후 수집만 빠진다. 다음 Space 방문·창 이동·앱 전환 수집은 남는다. relocator는 Mission Control이 이미 열려 있거나, raw identifier·display ID·child count·이동 대상 thumbnail action·frame 중 하나라도 snapshot과 맞지 않으면 drag 전에 `false`로 끝난다. 현재·마지막 Space처럼 제거할 수 없는 다른 thumbnail의 action은 요구하지 않는다. 입력 합성 뒤에도 성공 반환을 믿지 않는다. controller가 같은 runtime SID·kind·opaque name, 전체 Space 집합과 current 상태, 다른 regular Space의 화면 소속·상대 순서, 관찰한 window membership을 새 stable snapshot으로 검증한다. 하나라도 다르면 다음 Space를 움직이지 않고 기존 방문 기반 창 복원만 계속한다.

**공개 대체재** — Space 전체를 화면 사이로 옮기는 공개 API는 없다. Apple이 제공하는 사용자 Mission Control drag를 보이는 UI 자동화로 재현하는 Debug 실험 경로다. SkyLight write, Dock 주입, SIP 변경은 사용하지 않는다.

---

## 7. DEBUG 전용 Space 진단 프로브

아래는 위 4·5절의 이름을 `App/Plugback/SpaceProbe.swift`가 독립적으로 다시 읽는 DEBUG 진단 경로다. 프로브 코드와 익명 JSON 출력은 Release binary에 들어가지 않는다.

| 이름 | 진단하는 것 |
|---|---|
| `SLSMainConnectionID` | SkyLight 연결 ID |
| `SLSCopyManagedDisplaySpaces` | 화면별 Space topology |
| `SLSCopySpacesForWindows` | raw 창의 Space membership |
| `SLSSpaceGetType` | 일반 Space `0`과 fullscreen/Split View Space `4` 구분 |
| `SLSSpaceCopyName` | Space의 opaque name 존재·유일성 |
| `SLSManagedDisplayGetCurrentSpace` | 화면별 현재 활성 Space |
| `_AXUIElementGetWindow` | AX 표준 창과 CGWindowID의 임시 join |

**깨졌을 때의 동작** — 모든 이름은 `dlopen`/`dlsym`으로 optional하게 연다. 심볼이 없거나 snapshot 형식이 예상과 다르면 익명 JSON의 `symbols`·`errors`에 실패를 기록하고 프로브를 종료한다. 프로필·UserDefaults·창 위치는 건드리지 않는다.

**공개 대체재** — Space topology·type·membership과 다른 앱 AX 창의 CGWindowID join을 함께 제공하는 공개 조합은 없다. 제품 경로로 승격된 이름과 달리 이 프로브의 익명 집계·진단 형식은 Release binary에 포함되지 않는다.

---

## 잠금 해제 알림에서 안 쓰기로 한 대안

**미뤄둔 회차를 「다음 앱 활성화」 때 소비한다.** `NSWorkspace.didActivateApplicationNotification`은 공개 API이고 실험실 · 자동 슬롯의 `ActivityWatcher`가 이미 구독하고 있다. 잠금을 풀면 사용자는 곧 무언가를 클릭하므로 「사용자가 돌아왔다」의 근사값이 된다.

채택하지 않은 이유는 타이밍이다 — 복원이 잠금 해제 직후가 아니라 **사용자가 앱을 만진 뒤**에 일어난다. 이미 창을 보고 있는 상태에서 배치가 바뀌는 것은 US-009가 막으려는 「창 튐」과 구분되지 않는다.

**위 두 이름이 깨지면 이쪽으로 간다.** 핵심 변경(「버려질 회차를 버리지 않고 들고 있는다」)은 두 방식이 공유하므로, 바꿔 끼우는 것은 소비 시점 한 곳이다.

---

## 점검

macOS 메이저 버전을 올릴 때 Release 경로의 1~5절과, Space 작업 중이면 DEBUG 경로 6·7절도 확인한다. 잠금 경로는 3분이면 된다.

1. 외장 화면을 뽑은 상태로 맥북을 잠근다 (또는 덮개를 닫아 재운다).
2. 잠긴 상태에서 외장 화면을 연결한다.
3. 잠금을 푼다 → **창이 제자리로 돌아오면 통과.**

`DisplayWatcherTests.testLockedConnectionIsDeferredUntilUnlock`은 잠금 판정을 스텁으로 갈아끼운다 — **판정 로직만 지키고, 이름이 살아 있는지는 검증하지 못한다.** 그건 위 수동 절차의 몫이다.
