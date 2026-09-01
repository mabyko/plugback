# macOS native fullscreen Space 복구와 순서 제어 조사

> 확인일: 2026-08-29
> 확인 환경: macOS 26.6.2, Xcode 26.6, macOS SDK 26.5
> 범위: Plugback이 임의의 타사 앱 창을 제어하는 경우. 자기 앱의 `NSWindow` 제어와 구분한다.

> **현재 제품 결정(2026-09-01):** 아래 내용은 기술 조사 기록이다. 타사 fullscreen 복원이 best-effort에 머물고 Split View·순서를 보장할 수 없어, Plugback은 전체 화면 복원 기능·설정과 raw `AXFullScreen` write를 제거했다. fullscreen 상태는 건너뛰기 판정에만 읽는다.

## 결론

| 기능 | 판정 | 이유 |
|---|---|---|
| 자기 앱 창의 native fullscreen 진입·해제 | **supported** | AppKit의 [`NSWindow.toggleFullScreen(_:)`](https://developer.apple.com/documentation/appkit/nswindow/togglefullscreen%28_%3A%29)이 공개 API다. Cocoa는 진입 때 새 Space를 만든다. |
| 임의 타사 앱의 single native fullscreen 재생성 | **best-effort experimental** | 공개 AX로 버튼을 누르는 경로와 비공개 raw `AXFullScreen` 쓰기 경로가 실제 도구에서 쓰인다. 그러나 앱별 지원·focus·전환 타이밍에 의존하며 모든 창에 대한 계약은 없다. |
| 타사 창을 지정한 화면에서 fullscreen으로 만들기 | **best-effort experimental** | fullscreen 전 일반 창을 목표 화면으로 옮긴 뒤 진입시키는 순서는 실전 도구가 사용한다. fullscreen 명령 자체에는 타사 창용 화면 인자가 없다. |
| fullscreen Space의 정확한 Mission Control 순서 복구 | **not reliably possible** | 공개 API에는 Space 열거·생성·순서 변경기가 없다. 생성 순서에 기대는 방법과 Mission Control UI 자동화는 휴리스틱이다. |
| private Dock/SkyLight로 Space 순서 변경 | **best-effort experimental**, 제품 경로로는 부적합 | 현재 yabai는 Dock 내부 구현을 찾아 scripting addition으로 Space를 옮긴다. 부분 SIP 해제와 OS 버전별 보수가 필요하다. |
| Split View의 pair·좌우·divider 정확 복구 | **not reliably possible** | 공개 AppKit은 자기 창의 tile 참여 가능성만 제공한다. 타사 두 창의 pairing·side·divider를 지정하는 공개 API는 없다. |

따라서 Plugback이 현실적으로 먼저 검증할 범위는 **single fullscreen을 목표 화면에 다시 만드는 것**이다. “저장된 fullscreen Space들을 동일한 순서로 정확히 재구축”은 그 실험이 성공해도 별도의 보장 불가능 영역으로 남는다.

## 1. 공개 AppKit이 보장하는 범위

AppKit은 앱이 소유한 `NSWindow`를 native fullscreen으로 전환하는 [`toggleFullScreen(_:)`](https://developer.apple.com/documentation/appkit/nswindow/togglefullscreen%28_%3A%29)을 제공한다. Apple의 full-screen 안내는 진입 시 Cocoa가 동적으로 새 Space를 만들고 창을 그곳으로 옮긴다고 설명한다. 전환은 실패할 수도 있어 AppKit에는 [`windowDidFailToEnterFullScreen(_:)`](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidfailtoenterfullscreen%28_%3A%29)도 있다. 즉 자기 창조차 즉시·무조건 성공하는 동기 작업으로 다루면 안 된다. [Apple Full-Screen Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/FullScreenApp/FullScreenApp.html)

화면 정보도 자기 창의 delegate callback으로는 전달된다. [`customWindowsToEnterFullScreen(for:on:)`](https://developer.apple.com/documentation/appkit/nswindowdelegate/customwindowstoenterfullscreen%28for%3Aon%3A%29)은 해당 창이 진입할 `NSScreen`을 인자로 받는다. 하지만 이것은 **그 앱의 delegate가 받는 animation callback**이지, Plugback이 다른 프로세스의 `NSWindow`와 목표 화면을 지정하는 API가 아니다.

Spaces에 대한 공개 AppKit surface는 제한적이다.

- [`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)은 “Space가 바뀌었다”만 알리고 ID나 순서를 주지 않는다.
- [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)는 자기 창이 모든 Space에 보일지, active Space로 이동할지, fullscreen/tile에 참여할지 같은 성향을 정한다. Space를 열거·생성·재정렬하지 않는다.
- [`NSWindow.isOnActiveSpace`](https://developer.apple.com/documentation/appkit/nswindow/isonactivespace)는 자기 창이 현재 active Space에 있는지만 읽는다.
- [`NSScreen.screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces)는 사용자 설정을 읽을 뿐 Space topology를 주지 않는다.

따라서 공개 AppKit만으로는 다른 앱 fullscreen 복구도, Mission Control 순서 복구도 할 수 없다.

## 2. 타사 창을 fullscreen으로 만드는 Accessibility 경로

### 2.1 공개 AX primitive

Accessibility API 자체는 신뢰받은 client가 다른 앱의 접근성 요소를 읽고 제어하도록 설계됐다. Apple은 attribute가 쓰기 가능한지 확인하는 [`AXUIElementIsAttributeSettable`](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable), 값을 쓰는 [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue), action을 요청하는 [`AXUIElementPerformAction`](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)을 공개한다. 대상 앱이 attribute/action을 지원하지 않거나 응답하지 않으면 `attributeUnsupported`, `actionUnsupported`, `cannotComplete` 등이 정상적인 실패 결과다.

공개 fullscreen 관련 상수는 창의 fullscreen 버튼 요소를 돌려주는 [`kAXFullScreenButtonAttribute`](https://developer.apple.com/documentation/applicationservices/kaxfullscreenbuttonattribute)다. 그 버튼에 공개 `AXPress` action을 요청하는 방식은 가능한 1차 경로다. 다만 Apple은 “그 요소가 full-screen button”이라고만 계약하며, 임의 앱에서 press가 항상 native fullscreen 진입을 완성하거나 목표 화면·Space 순서를 받는다고 계약하지 않는다.

실행 전에는 [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)로 Accessibility 권한을 확인해야 한다. 권한 prompt는 비동기이며 호출 반환값을 바꾸지 않는다는 점도 전환 state machine에 반영해야 한다.

### 2.2 raw `AXFullScreen`

SDK 26.5의 공개 `AXAttributeConstants.h`와 Apple의 [ApplicationServices constants 목록](https://developer.apple.com/documentation/applicationservices/applicationservices_constants)에는 `kAXFullScreenButtonAttribute`는 있지만 현재 상태용 `kAXFullScreenAttribute`는 없다. 아래 점검도 상태 상수가 없고 버튼 상수만 있음을 재현한다.

```sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"
rg -n "AXFullScreen" \
  "$SDK/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers"
```

그럼에도 raw 문자열 `"AXFullScreen"`은 실제로 읽고 쓸 수 있는 앱이 많다.

- Hammerspoon은 [`AXUIElementSetAttributeValue(..., CFSTR("AXFullScreen"), ...)`](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/Hammerspoon/HSuicore.m#L860-L871)로 임의 창의 fullscreen 상태를 설정한다.
- yabai도 [`kAXFullscreenAttribute = CFSTR("AXFullScreen")`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window.h#L1-L5)를 자체 선언하고, native-fullscreen toggle에서 [그 값을 `true` 또는 `false`로 쓴다](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window_manager.c#L2296-L2324).
- yabai 구현은 먼저 창을 focus하고 그 창의 Space가 active가 될 때까지 기다린 다음 값을 쓰며, 전환 뒤 animation 종료도 기다린다. 이는 단순 attribute write 한 번보다 **focus → active Space → write → stable verification**이 필요한 실물 동작임을 보여준다. [yabai source](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window_manager.c#L2296-L2324)

이 증거는 “동작하는 실험 경로가 있다”는 뜻이지 Apple의 호환성 계약이 생겼다는 뜻은 아니다. 각 창마다 다음을 preflight해야 한다.

1. raw attribute가 실제 attribute 목록에 있다.
2. `AXUIElementIsAttributeSettable`이 성공하고 `true`다.
3. 창이 standard·resizable이며 fullscreen을 지원한다.
4. 창을 focus하고 source Space가 active다.
5. write 성공 뒤 `AXFullScreen == true`, 새 type-4 Space, 창 membership이 함께 안정화된다.

하나라도 실패하면 버튼 press를 한 번 시도하거나 해당 창을 unsupported로 남겨야 한다. 무한 retry나 keyboard shortcut fallback은 앱 상태를 추측하므로 넣지 않는다.

## 3. 목표 화면 지정

raw `AXFullScreen` 쓰기에는 화면 인자가 없다. 가장 작은 실험 경로는 **일반 창일 때 목표 화면으로 먼저 이동한 뒤 fullscreen으로 진입**시키는 것이다. yabai의 rule 적용도 display/Space 이동을 먼저 수행하고, 필요하면 그 Space를 focus한 다음, 마지막에 `AXFullScreen=true`를 쓴다. [yabai `rule.c`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/rule.c#L119-L156)

Apple도 여러 화면의 Split View에는 “Displays have separate Spaces”가 켜져 있어야 한다고 명시한다. [Apple Split View 안내](https://support.apple.com/en-asia/guide/mac-help/mchl4fbe2921/mac) 이 설정이 꺼져 있거나, 창이 목표 화면으로 완전히 이동하지 못했거나, 전환 중 사용자가 focus를 바꾸면 결과 화면을 보장할 수 없다.

따라서 목표 화면은 명령 인자가 아니라 사전 배치로 유도하고, 완료 뒤 private read-only topology로 검증하는 **best-effort**다. 검증 결과가 다른 화면이면 자동으로 Space를 다시 옮기지 말고 실패로 끝낸다.

## 4. fullscreen Space 순서

### 4.1 공개 API: 정확 복구 불가

Apple의 사용자 문서는 fullscreen과 Split View가 Spaces bar의 thumbnail로 나타나며, 사용자가 Mission Control에서 Space를 만들고 창을 옮기고 삭제하는 절차를 설명한다. [Apple 여러 Spaces 안내](https://support.apple.com/en-asia/guide/mac-help/-mh14112/mac) 공개 개발자 API에는 그 bar의 ordered Space 목록이나 `create/move/swap Space`가 없다. 공개 표면에서 얻는 것은 변경 알림과 자기 창 behavior뿐이다.

또한 macOS에는 “Automatically rearrange Spaces based on most recent use” 설정이 있고, Apple은 최근 사용 순서로 더 빨리 접근하도록 Space를 재배열한다고 설명한다. [Desktop & Dock 설정](https://support.apple.com/en-gb/guide/mac-help/-mchlp1119/mac) 이 설정이 켜진 환경에서 저장된 절대 순서를 지속적으로 보장하는 것은 OS 동작과 충돌한다.

fullscreen을 원하는 순서대로 하나씩 생성하면 현재 OS에서 그 순서대로 놓일 가능성은 있다. 그러나 Apple은 새 fullscreen Space의 삽입 위치를 계약하지 않으며, focus 자체가 최근 사용 순서를 바꿀 수 있다. 그러므로 이 방법은 먼저 실측할 **creation-order heuristic**일 뿐 제품 보장이 아니다.

### 4.2 Mission Control UI automation: 가능성은 있으나 불안정

Dock이 Mission Control을 표시할 때 생기는 Accessibility tree를 찾아 thumbnail을 누르거나 drag하는 방법은 SIP 없이 실험할 수 있다. Apple도 UI scripting을 마우스 click과 keyboard input을 모사해 여러 앱을 제어하는 방법으로 설명한다. [Apple UI scripting guide](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AutomatetheUserInterface.html) 다만 Dock의 AX hierarchy와 element identifier는 공개 Space API가 아니다. Hammerspoon의 공식 소스도 `hs.spaces`를 “private APIs와 Accessibility hacks를 섞은 experimental 기능”으로 규정하고, Mission Control UI가 실제로 표시돼야 하며 안정화를 위한 장치별 wait time이 필요하다고 설명한다. [Hammerspoon `spaces.lua`](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L2-L14), [wait-time 설명](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L204-L212)

Hammerspoon에는 Space thumbnail을 누르는 구현은 있지만 ordered drag API는 없다. Plugback이 직접 drag를 합성하면 좌표·animation·다중 화면·Dock AX 구조에 더 강하게 결합한다. 따라서 UI drag는 사용자에게 보이는 **best-effort experimental fallback**일 뿐 exact restore의 근거가 될 수 없다.

### 4.3 private SkyLight/Dock: lab에서는 강하지만 제품에는 부적합

yabai의 현재 CLI는 같은 화면에서 Space를 `--move`/`--swap`하는 명령을 제공하지만 둘 다 부분 SIP 해제를 요구한다. [yabai manual](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/doc/yabai.asciidoc#L291-L329) 실제 구현은 Space ID들을 받은 뒤 scripting addition에 “다른 Space 뒤로 이동”을 요청한다. [yabai `space_manager.c`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L801-L888)

그 scripting addition은 Dock에 들어가 OS 버전별 binary pattern으로 내부 `moveSpace` 함수를 찾고, Dock의 private object/ivar와 함께 호출한다. [주소 탐색](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L326-L362), [실제 move](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L460-L508) 이는 정확한 순서 변경의 기술적 가능성은 보여주지만, OS 업데이트마다 깨질 수 있고 Dock 주입과 SIP 변경을 요구한다.

yabai의 same-display move 함수에는 type-0만 허용하는 guard가 없으므로 type-4 Space도 받아들일 가능성이 있다. 하지만 위 소스만으로 fullscreen/Split pair 보존을 보장할 수는 없다. Plugback에 넣기 전에 별도 lab에서 type-4를 3회 이상 왕복해 검증해야 한다. 이 경로는 mainstream 제품 요구사항으로 잡지 않는다.

## 5. Split View는 별도 문제다

[`fullScreenAllowsTiling`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenallowstiling)은 자기 창이 secondary full-screen tile이 될 **자격**을 표현한다. partner, leading/trailing side, divider ratio를 설정하는 API가 아니다. 시스템은 크기 조건에 따라 그 창을 tile에 넣지 않을 수도 있다.

Apple이 문서화한 Split View 생성 방법은 사용자가 첫 창의 green-button 메뉴에서 좌우를 고르고 두 번째 창을 선택하거나, Mission Control에서 두 번째 창을 fullscreen thumbnail 위에 끌어놓는 방식이다. Split View는 새 desktop Space 하나에 만들어지고 divider는 사용자가 드래그한다. [Apple Split View 안내](https://support.apple.com/en-asia/guide/mac-help/mchl4fbe2921/mac)

따라서 raw `AXFullScreen=true`를 두 창에 순서대로 쓰면 보통 fullscreen Space 두 개를 만들 뿐, 같은 Split View pair가 된다는 계약이 없다. green-button popover나 Mission Control drag를 UI 자동화하면 pair를 만들 가능성은 있지만 다음을 정확히 보장하지 못한다.

- 어떤 두 문서 창을 pair할지
- 어느 창이 leading/trailing인지
- divider fraction
- 다중 화면 중 어느 화면인지
- OS 업데이트와 언어에 따른 메뉴·AX hierarchy 변화

single fullscreen 실험이 안정화되기 전에는 Split View 자동 생성을 구현하지 않는 것이 가장 작고 안전하다.

## 6. SIP와 배포 경계

| 경로 | SIP | 배포 판단 |
|---|---|---|
| 공개 fullscreen-button AX action | 해제 불필요, Accessibility 권한 필요 | direct distribution에서 실험 가능 |
| raw `AXFullScreen` read/write | 해제 불필요, Accessibility 권한 필요 | 비공개 attribute이므로 호환성·App Review 위험 |
| Mission Control AX/UI automation | 해제 불필요, Accessibility 권한 필요 | 화면 전환이 보이고 UI 구조에 취약 |
| SkyLight read-only topology | 현재 SIP 해제 불필요 | private API, fail-closed와 OS별 실기기 게이트 필요 |
| yabai식 Dock scripting addition 순서 변경 | **부분 SIP 해제 필요** | 일반 사용자 제품 경로로 부적합 |

Mac App Store 앱은 App Sandbox가 필수이며, Apple은 sandbox에서 assistive app의 Accessibility API 사용을 금지 활동으로 명시한다. [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [금지 활동 목록](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) 또한 App Review Guideline 2.5.1은 App Store 앱이 공개 API만 사용하도록 요구한다. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

따라서 이 기능을 유지하려면 현실적인 배포는 **non-sandboxed Developer ID direct distribution + notarization + 사용자 Accessibility 승인**이다. Apple은 Developer ID로 Mac App Store 밖에 배포하고 notarization할 수 있다고 안내한다. [Developer ID](https://developer.apple.com/support/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 7. Plugback 최소 실기기 prototype

제품 모델과 저장 형식부터 바꾸지 않는다. DEBUG 전용 one-shot probe 하나로 가능성만 판정한다.

### 단계 A — single fullscreen과 목표 화면

1. 사용자가 Zed 일반 창 하나를 선택하고 목표 외장 화면 A를 지정한다.
2. 기존 AX/WindowServer join으로 창을 고정한다. 둘 이상 후보면 중단한다.
3. raw `AXFullScreen` 존재·Boolean·settable을 점검한다.
4. 기존 gateway로 일반 창을 A 안쪽에 옮기고, 창을 focus한다.
5. `AXFullScreen=true`를 한 번만 쓴다.
6. 최대 8초 동안 snapshot을 읽되, 같은 결과 2회가 나올 때만 완료한다.
7. `false`를 한 번 써 원래 windowed 상태로 되돌리고 같은 방식으로 검증한다.
8. Zed와 Buzz에서 각각 3회 반복한다.

**pass**

- 매회 AX write가 `.success`다.
- 진입 뒤 목표 화면 A에 새 type-4 Space가 정확히 하나 생긴다.
- 대상 WindowServer ID의 membership이 그 type-4 하나이고 `AXFullScreen == true`다.
- 해제 뒤 그 type-4가 사라지고 창이 일반 Space로 돌아온다.
- 6/6 반복에서 다른 창·Space를 움직이지 않는다.

**fail**

- attribute가 없거나 settable이 아니다.
- write 성공인데 8초 안에 topology가 수렴하지 않는다.
- 잘못된 화면에 생기거나 membership이 ambiguous하다.
- 사용자가 입력하지 않았는데 다른 창/Space가 바뀐다.

### 단계 B — creation-order heuristic

단계 A가 통과한 뒤에만 한다.

1. A에서 Zed와 Buzz를 모두 windowed로 둔다.
2. 저장하고 싶은 순서대로 Zed, Buzz에 단계 A를 순차 실행한다. 앞 transition이 stable하기 전에는 다음 창을 건드리지 않는다.
3. 두 type-4의 화면 내 local order와 membership을 기록한다.
4. 둘 다 해제하고 같은 순서로 3회 재생성한다.
5. 마지막으로 A → B → A 연결 회차에서 한 번 재생성한다.

**pass**: 4/4 clean run에서 type-4 두 개가 목표 화면에 같은 상대 순서로 나타나고 membership이 뒤바뀌지 않는다.
**fail**: 한 번이라도 순서·화면·membership이 다르면 creation order를 복원 기능으로 채택하지 않는다.

이 gate가 통과해도 판정은 **best-effort experimental** 그대로다. Apple 계약이 아니라 현재 OS의 관찰값이기 때문이다. “Automatically rearrange Spaces”가 켜진 상태의 장기 순서는 별도 실패 가능성으로 사용자에게 명시한다.

### 다음 단계

- 단계 A 실패: fullscreen 자동 복구를 제품 범위에서 제외한다.
- 단계 A 통과, B 실패: fullscreen 상태와 목표 화면만 복구하고 순서는 macOS에 맡긴다.
- A/B 모두 통과: DEBUG opt-in으로 한 버전 운영한 뒤 OS 업데이트별 gate를 둔다.
- Split View: single fullscreen 경로가 운영 데이터에서 안정적일 때만 별도 prototype으로 시작한다.
- private Dock injection: Plugback 제품에는 넣지 않는다.
