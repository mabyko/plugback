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

**키가 없거나 조회에 실패하면** — 현재 구현은 세션 조회 실패·키 누락·형식 불일치를 모두 「잠기지 않음」으로 처리한다. 잠금 미루기가 적용되지 않아 억제 구간의 연결을 놓칠 수 있고, 다른 조건이 통과하면 잠금 중 복원을 시도할 수도 있다. 따라서 위 원칙의 「잘못된 복원도 없다」가 현재 잠금 경로에서 보장된다고 볼 수 없다.

2026-09-10 단일 조회에서는 세션 사전은 있었지만 이 키는 없었다. 이 사실만으로 실제 잠금 상태나 비공식 키의 고장을 단정하지 않는다. 키가 없는 상태를 전부 오류로 바꾸는 것도 확정하지 않았으며, 실제 잠금 전·중·후 값과 알림 순서를 함께 검증해야 한다. 연결·해제 순서의 별도 문제와 보완 검토는 [Space 상태 검토 1.1절](./SPACE_LAYOUT_STATE_REVIEW.md)에 있다.

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
| **무엇을 판정** | 대상 앱 표준 창의 native fullscreen 상태를 읽어 저장·이동 대상에서 제외 |
| **공개 여부** | 현재 SDK의 공개 AX attribute 상수에 없는 raw 문자열이다 |

**깨졌을 때의 동작** — attribute 부재·타임아웃·타입 불일치는 `unknown`이 된다. Space binding 경로는 `unknown` 창을 움직이지 않는다. 제품은 이 attribute를 쓰지 않으며 settable 여부도 확인하지 않는다.

**공개 대체재** — 다른 앱의 현재 native fullscreen 상태를 직접 주는 공개 AX attribute는 확인되지 않았다. 공개 `kAXFullScreenButtonAttribute` 요소의 존재는 현재 상태가 아니므로 판정 대체재가 아니다.

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

**쓰는 곳** — `SpaceReader`. 모두 조회만 하며 Space·창을 변경하는 SkyLight 함수는 로드하지 않는다. type `4`는 일반 Space로 오인하지 않기 위해 구분할 뿐, 앱 후보를 찾거나 복원하지 않는다.

**깨졌을 때의 동작** — 심볼 하나라도 없거나 dictionary 형식·화면 ID·현재 Space가 예상과 다르거나 연속 두 snapshot이 다르면 `.unavailable`이다. 이 값은 reader 부재나 의도적인 Space 생략과 구별된다. 명시적 저장·대상 추가·자동 수집은 기존 프로필·Space overlay·후보를 보존하고, 카드는 저장된 Space 행의 현재 상태만 확인 불가로 표시한다. Space overlay가 없는 legacy 프로필은 기존 복원을 유지하지만, binding이 있는 앱은 평면 복원으로 강등하지 않고 건너뛴다. raw Space ID·CGWindowID는 메모리 밖으로 나가지 않는다.

**공개 대체재** — 화면별 Space topology·type·membership을 함께 제공하는 공개 API는 없다.

---

## 6. Mission Control Dock AX tree — 안내 재확인과 자동 수집

| 이름 | 쓰는 것 |
|---|---|
| `mc` | Mission Control 회차가 열리고 닫혔는지 확인 |
| `AXSelectedChildrenChanged`, `AXUIElementDestroyed` | `mc` tree를 본 Mission Control 회차가 닫힌 시점 감지 |

**쓰는 곳** — `MissionControlWatcher`. `PlugbackController`가 인스턴스 하나를 소유해 Mission Control 닫힘을 한 번으로 압축한다. 진행 중 안내형 recovery를 먼저 재확인하고, recovery가 없을 때만 자동 슬롯을 수집한다. 두 notification 이름 자체는 공개 AX 상수지만 Dock의 `mc` identifier와 tree 수명은 공개 계약이 아니다.

**깨졌을 때의 동작** — `mc` tree를 보지 못하거나 닫힘 notification이 오지 않으면 이동 직후 안내 갱신과 자동 수집이 빠진다. 사용자가 옮긴 Space를 열면 공개 활성 Space 이벤트가 같은 recovery를 다시 확인하므로 창 복원은 이어질 수 있다. 창 이동·앱 전환 수집도 남는다.

**공개 대체재** — Mission Control 닫힘을 직접 알려주는 공개 notification은 없다. 사용자가 Space를 방문하거나 창·앱을 움직이는 다른 수집 신호는 남는다.

---

## 7. DEBUG 전용 Space 진단·왕복 프로브

아래는 위 4·5절의 이름을 `App/Plugback/SpaceProbe.swift`가 독립적으로 다시 읽는 DEBUG
진단 경로다. `--space-probe`와 `--space-reader-probe`는 조회만 한다. `--space-relocation-probe`는
layer `0` 창이 없는 희생용 Space만 즉시 한 번 왕복한다. 앱 창 포함 실기기 실패 뒤 Debug 설정의
write 패널은 제거했다. 프로브 코드·CLI 익명 JSON 출력은 Release binary에 들어가지 않는다.

| 이름 | 진단하는 것 |
|---|---|
| `SLSMainConnectionID` | SkyLight 연결 ID |
| `SLSCopyManagedDisplaySpaces` | 화면별 Space topology |
| `SLSCopySpacesForWindows` | raw 창의 Space membership |
| `SLSSpaceGetType` | 일반 Space `0`과 fullscreen/Split View Space `4` 구분 |
| `SLSSpaceCopyName` | Space의 opaque name 존재·유일성 |
| `SLSManagedDisplayGetCurrentSpace` | 화면별 현재 활성 Space |
| `_AXUIElementGetWindow` | AX 표준 창과 CGWindowID의 임시 join |
| `SLSBridgedCopyManagedDisplaySpacesOperation` | AppKit WM bridge가 실제 read operation을 수행하는지 확인 |
| `SLSBridgedMoveManagedSpaceToDisplayIndexOperation` | 선택한 희생용 Space의 destination 이동 1회와 source 역이동 1회 |

**write gate** — build `25G83`, Objective-C method encoding, read bridge, Mission Control 닫힘,
Dock PID, stable topology 두 회, 별도 화면, 유일한 **빈** 비활성 type `0` tail Space를 모두 확인한다.
CLI는 destination 끝으로 한 번 보낸 뒤 저장한 source index로 한 번 되돌린다.
raw wrapper·retry·Space create/destroy는 없다.

**깨졌을 때의 동작** — read 이름은 `dlopen`/`dlsym`, bridged operation은 runtime class·typed
`objc_msgSend`로 연다. write 전 조건이 하나라도 다르면 `rejected-before-write`로 끝난다.
async write 뒤에는 최대 8초 동안 topology를 다시 읽는다. 예상 topology가 아니면 목적 화면에서
대상 SID가 정확히 확인될 때만 원래 index로 한 번 복구하고, 그 밖에는 다른 위치를 추측하지 않는다.
프로필·UserDefaults·창 위치는 건드리지 않는다. 앱 창 포함 회차에서는 transient baseline을 복귀
성공으로 오판한 뒤 대상 SID가 지연 이동하고 Mission Control thumbnail에서 사라졌으므로 이 입력은
validator가 항상 write 전에 거절한다.

**공개 대체재** — Space topology·type·membership, 다른 앱 AX 창의 CGWindowID join, whole-Space
화면 이동을 제공하는 공개 조합은 없다. 빈 Space 왕복 3/3과 무관하게 앱 창 포함 회차가 실패했으므로
이 write를 제품 경로로 승격하지 않는다.

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
