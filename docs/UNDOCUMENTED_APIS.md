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
| **쓰는 곳** | `AXWindowGateway.standardWindows()` |
| **무엇을 판정** | 대상 앱의 표준 창이 native fullscreen인가 |
| **공개 여부** | 현재 SDK의 공개 AX attribute 상수에 없는 raw 문자열이다 |

**깨졌을 때의 동작** — attribute 부재·타임아웃·타입 불일치는 `unknown`이 된다. 기존 flat 경로의 `isFullscreen` 호환값은 종전처럼 `false`지만, Space-aware 경로는 3상태 값을 직접 보고 `unknown` 창을 움직이지 않는다.

**공개 대체재** — 다른 앱의 현재 native fullscreen 상태를 직접 주는 공개 AX attribute는 확인되지 않았다. full-screen 버튼 요소의 존재는 현재 상태가 아니다.

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

**쓰는 곳** — `SpaceReader`. 모두 조회만 하며 Space·창을 변경하는 SkyLight 함수는 로드하지 않는다.

**깨졌을 때의 동작** — 심볼 하나라도 없거나 dictionary 형식·화면 ID·현재 Space가 예상과 다르거나 연속 두 snapshot이 다르면 `.unavailable`이다. 기존 flat 복원은 그대로이고 Space-aware 경로만 꺼진다. raw Space ID·CGWindowID는 메모리 밖으로 나가지 않는다.

**공개 대체재** — 화면별 Space topology·type·membership을 함께 제공하는 공개 API는 없다.

---

## 6. DEBUG 전용 Space 진단 프로브

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

macOS 메이저 버전을 올릴 때 Release 경로의 1~5절과, Space 작업 중이면 DEBUG 프로브도 확인한다. 잠금 경로는 3분이면 된다.

1. 외장 화면을 뽑은 상태로 맥북을 잠근다 (또는 덮개를 닫아 재운다).
2. 잠긴 상태에서 외장 화면을 연결한다.
3. 잠금을 푼다 → **창이 제자리로 돌아오면 통과.**

`DisplayWatcherTests.testLockedConnectionIsDeferredUntilUnlock`은 잠금 판정을 스텁으로 갈아끼운다 — **판정 로직만 지키고, 이름이 살아 있는지는 검증하지 못한다.** 그건 위 수동 절차의 몫이다.
