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
| **쓰는 곳** | `ScreenLock.current()` — `DisplayWatcher`의 잠금 미루기와 복원 요청의 실행 게이트(F-02.6)가 쓴다 |
| **무엇을 판정** | 지금 화면이 잠겨 있나 — 잠김 · 안 잠김 · 판정 불가 |
| **공개 여부** | 함수 `CGSessionCopyCurrentDictionary()`는 **공개** — `CGSession.h`, macOS 10.3+. **키는 헤더에 없다.** |

헤더가 선언한 세션 키는 다섯뿐이다 — `UserID` · `UserName` · `ConsoleSet` · `OnConsole` · `LoginDone`. 잠금 키는 그중에 없다. 확인:

```sh
grep -n "kCGSession" "$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreGraphics.framework/Headers/CGSession.h"
```

**판정 규칙 (2026-09-11)** — 세션 사전 조회 실패는 **판정 불가**, 사전은 있는데 키가 없으면 **안 잠김**, 키가 `Bool`이 아니면 **판정 불가**다. 2026-09-10·11의 잠금 해제 상태 조회 두 번에서 키가 없었으므로 키 부재를 안 잠김으로 읽는다. 실제 잠금 중의 값과 알림 순서는 실기기 검증 항목이다.

**깨지면 무슨 일이 나나** — 키가 사라지면 항상 안 잠김으로 읽혀 잠금 미루기만 꺼진다(이 기능을 넣기 전 동작). 조회 자체가 실패하면 판정 불가가 되어 복원 요청은 미전송 조작을 「잠금 상태를 확인하지 못해 대기」로 보류하고, 잠금 해제 알림·사용자의 「남은 창 복원」에서 다시 확인한다. 잘못된 복원은 없고, 사례는 진단 기록에 남는다.

**공개 대체재** — 없다. `NSWorkspace`에 잠금 상태를 묻는 API가 없다.

---

## 2. `com.apple.screenIsUnlocked` — 잠금 해제 알림

| | |
|---|---|
| **쓰는 곳** | `DisplayWatcher.start()` — `DistributedNotificationCenter` 구독 |
| **무엇을 트리거** | 미뤄둔 등장 회차의 소비 (F-01.3)와 잠금 보류 항목의 재개 (F-02.6) |
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

**깨졌을 때의 동작** — `dlsym` 실패나 개별 join 실패는 `WindowInfo.windowServerID == nil`이 된다. Space 없는 기록의 복원은 그대로 동작하고, Space 기록 경로는 그 창을 후보로 쓰지 않는다. 창 연결(저장 자리 ↔ 창 ID)도 만들 수 없어 창 대응은 매번 추정 배정이 되고 닫힌 환경 판정이 빠진다. ID는 저장하거나 로그에 남기지 않는다.

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

**깨졌을 때의 동작** — 심볼 하나라도 없거나 dictionary 형식·화면 ID·현재 Space가 예상과 다르거나 연속 두 snapshot이 다르면 `.unavailable`이다. 이 값은 reader 부재나 의도적인 Space 생략과 구별된다. 명시적 저장·자동 수집은 기존 저장본·저장 대기 이력을 보존하고, 카드는 저장된 Space 행의 현재 상태만 확인 불가로 표시한다. Space 정보가 없는 구버전 기록은 위치 복원을 유지하지만, Space가 지정된 기록은 평면 복원으로 강등하지 않고 「확인 필요」로 남긴다. raw Space ID·CGWindowID는 메모리 밖으로 나가지 않는다.

**공개 대체재** — 화면별 Space topology·type·membership을 함께 제공하는 공개 API는 없다.

---

## 6. Mission Control Dock AX tree — 안내 재확인과 자동 수집

| 이름 | 쓰는 것 |
|---|---|
| `mc` | Mission Control 회차가 열리고 닫혔는지 확인 |
| `AXSelectedChildrenChanged`, `AXUIElementDestroyed` | `mc` tree를 본 Mission Control 회차가 닫힌 시점 감지 |

**쓰는 곳** — `MissionControlWatcher`. `PlugbackController`가 인스턴스 하나를 소유해 Mission Control 닫힘을 한 번으로 압축한다. 진행 중 복원 요청의 방문 대기·이동 안내를 먼저 재판정하고, 그 뒤 저장 대기 이력을 수집한다. 두 notification 이름 자체는 공개 AX 상수지만 Dock의 `mc` identifier와 tree 수명은 공개 계약이 아니다.

**깨졌을 때의 동작** — `mc` tree를 보지 못하거나 닫힘 notification이 오지 않으면 이동 직후 안내 갱신과 자동 수집이 빠진다. 사용자가 옮긴 Space를 열면 공개 활성 Space 이벤트가 같은 recovery를 다시 확인하므로 창 복원은 이어질 수 있다. 창 이동·앱 전환 수집도 남는다.

**공개 대체재** — Mission Control 닫힘을 직접 알려주는 공개 notification은 없다. 사용자가 Space를 방문하거나 창·앱을 움직이는 다른 수집 신호는 남는다.

---

## 7. `com.apple.spaces` `spans-displays` — 개별 Spaces 설정 (D6)

| | |
|---|---|
| **쓰는 곳** | `SpacesSupport.fromPreferences()` |
| **무엇을 판정** | 「각각의 Spaces가 있는 디스플레이」가 켜져 있나 (F-01.5) |
| **공개 여부** | 시스템 설정이 쓰는 환경설정 도메인·키이며 공개 API 계약이 아니다. `CFPreferencesCopyAppValue`로 읽기만 한다 |

값이 없으면 macOS 기본값(개별 Spaces ON)으로 본다. `1`/`true`면 공유 구성, 그 밖의 형식은 판정 불가다. 연결된 화면이 둘 이상인데 Space 관찰의 managed display가 그보다 적으면 설정 값과 무관하게 공유 구성으로 본다.

**깨졌을 때의 동작** — 키가 사라지면 개별 Spaces로 읽고 관찰 교차 확인이 남는다. 형식이 바뀌면 판정 불가가 되어 새 Space 기록의 저장·복원을 보류하고 기존 기록·안내를 유지한다. 위치 전용 복원으로 전환하지 않는다.

**공개 대체재** — 없다. 설정 전환·재로그인 뒤의 값은 실기기 검증 항목이다.

---

## 8. IORegistry 포트 속성 — 화면 표시 이름의 포트 위치 (P20)

| 이름 | 읽는 것 |
|---|---|
| `IOPortTransportStateDisplayPort` 노드의 `EDID`, `ParentBuiltInPortType`, `ParentBuiltInPortNumber` | 어느 내장 포트에 어떤 모니터(EDID 제조사·제품·시리얼)가 연결됐나 |
| `AppleHPMBusDevice`(DeviceTree `hpmN`) 노드의 `port-type`, `port-number`, `port-location` | 포트 번호와 본체 위치 문자열 (`left-back`, `left-front`, `right`) |

**쓰는 곳** — `PortLocator` (`SystemScreenProvider`). 화면 대응은 EDID의 제조사·제품·시리얼을 화면 지문과 맞춰서 한다. 2026-09-11 M2 Max 한 대·LG HDR 4K 한 대에서 확인한 구조이며, 독·DisplayLink·다른 맥 모델·동일 모델 여러 대는 미검증이다.

**깨졌을 때의 동작** — 노드·키가 없거나 대응이 둘 이상이면 위치를 `nil`로 두어 표시하지 않고, 같은 이름의 화면은 A/B로 구분한다. 저장본·복원에는 영향이 없다 — 포트 위치는 키가 아니다.

**공개 대체재** — 화면과 본체 포트 위치를 함께 주는 공개 API는 확인되지 않았다.

---

## 9. DEBUG 전용 Space 진단·왕복 프로브

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

macOS 메이저 버전을 올릴 때 Release 경로의 1~8절과, Space 작업 중이면 DEBUG 경로 9절도 확인한다. 잠금 경로는 3분이면 된다.

1. 외장 화면을 뽑은 상태로 맥북을 잠근다 (또는 덮개를 닫아 재운다).
2. 잠긴 상태에서 외장 화면을 연결한다.
3. 잠금을 푼다 → **창이 제자리로 돌아오면 통과.**

`DisplayWatcherTests.testLockedConnectionIsDeferredUntilUnlock`과 `DisplayLockReproductionTests`, `RestoreSessionTests.testLockHoldsUnsentMovesAndUnlockResumesOnlyThoseItems`는 잠금 판정을 스텁으로 갈아끼운다 — **판정 로직만 지키고, 이름이 살아 있는지는 검증하지 못한다.** 그건 위 수동 절차의 몫이다.
