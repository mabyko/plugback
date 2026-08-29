# 일반 Space의 화면 간 이동 조사

> 확인일: 2026-08-29
> 환경: macOS 26.6.2 (25G83), Apple Silicon, Xcode 26.6, macOS SDK 26.5
> 전제: **Displays have separate Spaces** 켬
> 범위: 일반 Space(type `0`)만. native fullscreen·Split View(type `4`)는 쓰기 대상에서 제외한다.

## 결론

| 작업 | 공개 API | SIP를 켠 실험 경로 | 판정 |
|---|---|---|---|
| 기존 일반 Space를 다른 화면으로 이동 | 프로그래밍 API 없음. Mission Control 수동 drag는 실기기 성공 | visible UI drag automation 또는 write 미검증 `SLSMoveManagedSpaceToDisplayIndex` | **수동 가능, 자동은 best-effort experimental** |
| 특정 화면에 일반 Space 생성 | 없음 | Mission Control의 Dock AX `mc.spaces.add` 누르기. raw `SLSSpaceCreate`는 목표 화면 결합 방법이 불명확 | **보이는 UI 자동화로 best-effort 가능** |
| 타사 창을 특정 일반 Space로 이동 | 없음 | yabai 7.1.25의 private SkyLight bridged operation 또는 compat-ID 경로 | **DEBUG 실기기 검증 가치가 가장 높음** |
| 생성한 일반 Space 삭제 | 없음 | Mission Control의 Dock AX `AXRemoveDesktop`. raw `SLSSpaceDestroy`는 존재하지만 쓰지 않음 | **빈 probe Space 정리에 한해 best-effort 가능** |

전체 Space 이동·직접 생성·직접 삭제를 조용히 수행하는 현재 yabai 경로는 Dock에 코드를 주입한다. yabai 문서도 `space --display`, `--create`, `--destroy`에 **부분 SIP 해제**가 필요하다고 명시한다. 반면 **창 하나를 특정 Space로 옮기는 일은 별도 경로**다. yabai 7.1.25부터 다시 SIP를 켠 채 동작하며, 현재 소스는 SkyLight의 private bridged operation을 먼저 쓴다. [yabai 명령 문서](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/doc/yabai.asciidoc#L291-L329), [7.1.25 변경 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L12-L15)

정확히 같은 Space를 되돌리는 것과 동등한 새 Space를 만드는 것은 분리해야 한다.

- **same-Space relocation**: 같은 runtime SID가 내장 화면에서 A로 옮겨지고 window membership도 그대로 남는다.
- **equivalent reconstruction**: A에 새 type `0` Space를 만들고 저장된 창들을 그 SID로 옮긴다. 원래 Space identity와 내부 화면의 topology는 그대로 복구되지 않는다.

첫 번째는 이미 **사용자의 Mission Control drag로 실기기에서 성공**했다. 자동화는 같은 visible drag를 재현하는 방법과 26.6.2의 raw move symbol을 빈 희생용 Space에 시험하는 방법이 있다. 둘 다 Apple의 프로그래밍 계약은 아니므로 제품 판정은 best-effort 그대로다. 실패하면 현실적인 대안은 두 번째다. 전체 Space 이동용 Dock 코드를 Plugback에 복제하거나 사용자에게 SIP 해제를 요구하지 않는다.

## 조사 기준과 고정 소스

- Apple 공개 계약: 현재 Apple 개발자 문서, 사용자 안내, 로컬 macOS 26.5 SDK 헤더.
- yabai: commit [`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd). 이 HEAD 자체가 “macOS 26.6 Apple Silicon의 scripting-addition `add_space` 수정”이다. [CHANGELOG](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L3-L9)
- Hammerspoon: commit [`23e387e2805a9890066366e0ac96c71b27f0cfd5`](https://github.com/Hammerspoon/hammerspoon/tree/23e387e2805a9890066366e0ac96c71b27f0cfd5).

두 프로젝트는 Apple API의 계약을 대신하지 않는다. 여기서는 **현재 공개 소스가 어떤 private call을 어떤 guard와 함께 쓰는지** 확인하는 1차 근거로만 사용한다.

## 공개 API의 상한

Apple은 사용자가 Mission Control에서 일반 Space를 만들고, 창을 다른 Space로 끌고, Space를 삭제하는 UI를 문서화한다. 삭제한 Space에 창이 있으면 macOS가 그 창을 다른 Space로 옮긴다. 그러나 기존 Space 전체를 다른 화면으로 옮기는 개발자 API나, 임의의 타사 창에 목적지 Space ID를 주는 API는 문서화하지 않는다. [Apple: Work in multiple spaces](https://support.apple.com/en-asia/guide/mac-help/-mh14112/mac)

공개 AppKit surface도 관찰·성향 지정에 그친다.

- [`NSScreen.screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces)는 설정을 읽는다.
- [`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)은 변경 사실만 알리며 `userInfo`가 없다.
- [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)는 **자기 앱 창**이 모든 Space에 보일지, 활성 Space로 따라갈지 등을 정한다. 임의의 Space ID를 받지 않는다.
- Accessibility의 [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)는 대상 요소가 제공하는 attribute만 쓸 수 있다. SDK의 공개 창 attribute에는 `AXPosition`, `AXSize`, `AXFullScreenButton`은 있지만 Space ID attribute는 없다.

로컬 SDK에서 다음을 확인했다.

```sh
SDK="$(xcrun --sdk macosx --show-sdk-path)" # MacOSX26.5.sdk

rg -n 'activeSpaceDidChange|screensHaveSeparateSpaces|isOnActiveSpace|CanJoinAllSpaces|MoveToActiveSpace' \
  "$SDK/System/Library/Frameworks/AppKit.framework/Headers"

rg -n 'kAX(Position|Size|FullScreenButton)|AXIsProcessTrusted|AXUIElementSetAttributeValue' \
  "$SDK/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers"

# 아래 private 이름은 SDK의 *.h에 0건
rg -n 'SLS(CopyManagedDisplaySpaces|MoveManagedSpaceToDisplayIndex|MoveWindowsToManagedSpace|SpaceCreate|SpaceDestroy|SpaceSetCompatID|SetWindowListWorkspace|ManagedDisplaySetCurrentSpace)' \
  "$SDK" -g '*.h'
```

이 결과는 “공개 API가 없다”는 검색 범위를 현재 SDK로 한정한다. private 이름이 런타임에 존재한다는 사실과 지원 계약은 별개다.

## macOS 26.6.2 SkyLight binary audit

현재 호스트의 dyld shared cache에 있는 SkyLight 자체를 1차 자료로 검사했다. 다음 명령은 write를 수행하지 않는다.

```sh
sw_vers
# ProductVersion: 26.6.2, BuildVersion: 25G83

SKYLIGHT=/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight
xcrun dyld_info -exports "$SKYLIGHT" | rg \
  'SLS(MoveManagedSpaceToDisplayIndex|SpaceCreate|SpaceDestroy|MoveWindowsToManagedSpace)|SLSBridged'
xcrun dyld_info -disassemble "$SKYLIGHT"
```

26.6.2에는 다음 C wrapper와 Objective-C class가 모두 존재한다.

| 작업 | exported wrapper | bridged operation의 현재 initializer |
|---|---|---|
| Space → display/index | `SLSMoveManagedSpaceToDisplayIndex` | `initWithSpaceID:displayIdentifier:index:` (`Q`, object, `I`) |
| Space 생성 | `SLSSpaceCreate` | `initWithOptions:values:` (`I`, object), 결과에 `spaceID` |
| Space 삭제 | `SLSSpaceDestroy` | `initWithSpaceID:` (`Q`) |
| windows → Space | `SLSMoveWindowsToManagedSpace` | `initWithWindows:spaceID:` (array, `Q`) |

arm64 disassembly와 Objective-C method encoding에서 추론되는 **이 빌드 한정** call shape은 다음과 같다. 이것은 Apple header나 ABI 계약이 아니다.

```c
void     SLSMoveManagedSpaceToDisplayIndex(int32_t cid,
                                           uint64_t sid,
                                           CFStringRef displayIdentifier,
                                           uint32_t index);
uint64_t SLSSpaceCreate(int32_t cid, uint32_t options, CFDictionaryRef values);
void     SLSSpaceDestroy(int32_t cid, uint64_t sid);
void     SLSMoveWindowsToManagedSpace(int32_t cid, CFArrayRef windowIDs, uint64_t sid);
```

중요한 제약이 있다. 네 wrapper 모두 내부의 `SLSWindowManagementClientOperationsEnabled` gate를 먼저 확인한다. 켜졌으면 bridged operation을 만들고 hidden performer를 호출하며, 아니면 예전 WindowServer client fallback으로 간다. 이 gate와 performer는 `dlsym` export가 아니고, local disassembly에는 feature flag·preference·entitlement/delegate 확인이 보인다. 일반 Developer ID 앱이 어느 branch를 타고 어떤 권한으로 성공하는지는 문서화되어 있지 않다.

최신 yabai도 window move에서는 exported wrapper만 믿지 않는다. SkyLight Mach-O의 local C++ performer를 직접 찾아 bridged object를 넘긴다. 반면 Space move/create/destroy에는 여전히 Dock scripting addition을 쓴다. 이는 raw Space wrapper가 실패한다는 증명은 아니지만, **현재 공개 소스에 일반 프로세스 성공 사례가 없다는 강한 경고**다. [yabai symbol lookup](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/yabai.c#L143-L150), [window bridged operation](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L665-L704)

역사적인 CGSInternal header에는 `CGSSpaceCreate(cid, null, options)`와 dictionary key `type`, `uuid`가 기록돼 있다. 하지만 2010년대 reverse-engineered header일 뿐이고, 현재 `SLSSpaceCreate`의 `values`에서 `uuid`가 Space UUID인지 display UUID인지도 검증되지 않았다. 이 자료로 목표 화면 생성 call을 추측해서는 안 된다. [CGSInternal `CGSSpace.h`](https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSSpace.h#L49-L61)

## 1. 기존 일반 Space를 다른 화면으로 이동

### 26.6.2 수동 Mission Control gate

A→B→A 뒤 A의 Space들이 내장 화면으로 밀린 실제 상태에서 사용자가 Mission Control을 열고, A의 두 번째 일반 Space thumbnail 하나를 내장 화면의 Spaces bar에서 A 외장 화면의 bar로 drag했다.

| 시점 | 내장 화면 | A 외장 화면 |
|---|---|---|
| drag 전 | regular `4` + type `4` 두 개 | regular `1` |
| drag 후 | regular `3` | regular `2` + type `4` 두 개 |

drag 후 연속 두 snapshot이 동일하게 안정화됐다. 옮긴 regular Space는 **기존 opaque name과 runtime SID를 그대로 유지**했고, Buzz/Zed의 type `4` 두 개도 외장 화면으로 함께 돌아왔다. 이후 Finder의 regular Space와 Buzz/Zed fullscreen Space를 방문했을 때 기존 상태와 위치가 유지됐다. 이 과정에서 Plugback의 AX window move와 fullscreen write 호출은 모두 `0`이었다.

따라서 이 OS와 topology에서는 **같은 Space 자체를 화면 사이로 옮기는 사용자 UI가 실제로 작동한다**. 더구나 fullscreen Space도 같은 외장 화면으로 다시 귀속됐다. 다만 한 회의 관찰만으로 “어떤 regular thumbnail을 옮기면 어느 type `4`가 따라오는지”에 대한 일반 규칙이나 exact local order를 추론하면 안 된다. 다음 회차에는 pre/post SID·display·local order·membership을 모두 기록해 3/3으로 재검증해야 한다.

이 성공은 자동화 가능성을 높이지만 공개 automation API를 만들지는 않는다. Hammerspoon이 쓰는 Dock AX tree에는 `mc.display`의 `AXDisplayID`와 화면별 `mc.spaces.list`가 있어 source thumbnail과 destination bar를 찾을 단서는 있다. Hammerspoon도 그 list의 child 순서와 private managed Space 순서를 대응시킨다. [display/group lookup](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L83-L150), [Space ID ↔ AX child mapping](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L621-L669) 그러나 기존 Space를 다른 화면으로 보내는 AX action은 확인되지 않았고, 실제 구현은 pointer drag 좌표·Mission Control animation·사용자 입력에 의존한다. 따라서 다음 구분을 유지한다.

- **사람이 직접 drag**: 현재 실기기에서 성공. 가장 안전한 assisted fallback.
- **Plugback이 visible drag를 합성**: SIP-on **best-effort experimental**. 정확한 thumbnail mapping과 전후 검증이 필수.
- **raw SkyLight move**: 화면을 열지 않을 가능성이 있지만 write 미검증이며 내부 gate가 있다.

### 판정

사용자 수동 UI 경로는 **실기기 성공**, 무인 자동 복구는 **not reliably possible**이 현재 제품 판정이다. visible drag 합성과 26.6.2의 `SLSMoveManagedSpaceToDisplayIndex`는 각각 **best-effort experimental** probe 후보다. 조용한 자동 이동이 공개 소스로 확인된 경로는 yabai식 Dock scripting addition뿐이다. 그 경로는 부분 SIP 해제와 OS별 binary pattern 유지보수가 필요하므로 Plugback 제품에는 넣지 않는다.

Hammerspoon의 고정된 `hs.spaces`에는 Space 생성·창 이동·삭제가 있지만, **기존 Space 전체를 다른 화면으로 옮기는 함수는 없다**. Apple 사용자 문서도 전체 Space의 화면 간 이동을 개발자 계약으로 제공하지 않는다. 따라서 실기기에서 성공한 thumbnail drag를 합성하려면 Plugback이 별도 UI prototype을 만들어야 한다.

### 26.6.2 raw 후보

현재 wrapper는 `(connection, source SID, destination display identifier, index)`를 받는다. bridged class도 같은 세 값을 저장하고 operation은 비동기로 수행된다. 따라서 가장 작은 검증은 **비어 있고 inactive인 임시 Space**를 다른 화면 끝으로 한 번 보낸 뒤 stable topology를 비교하는 것이다.

성공 조건은 단순히 destination의 Space 수가 늘어나는 것이 아니다.

- 같은 runtime SID와 opaque name이 destination display에 나타난다.
- source에서는 그 SID만 사라지고 다른 Space 순서는 유지된다.
- 해당 SID의 window membership은 그대로다.
- 요청한 `index`와 실제 local order의 관계가 일관된다.
- Dock crash/relaunch, desktop picture 이상, current-Space 변경이 없다.

wrapper가 `void`이고 operation도 async이므로 호출 반환으로 성공을 알 수 없다. 또한 `index`가 0-based인지, 범위를 벗어난 값을 clamp하는지는 공개 계약이 없다. 첫 probe는 기존 Space가 없는 새 identity를 만들지 않고, 사용자가 직접 만든 빈 임시 Space에 한해 destination의 마지막 위치 하나만 시도해야 한다. 자동 retry로 다른 index를 시험하지 않는다.

### yabai의 정확한 흐름

호출자는 source Space ID와 destination display ID를 받는다. 다음 guard를 통과해야 한다.

1. Mission Control이 열려 있지 않다.
2. source와 destination 화면이 다르다.
3. 두 화면 모두 전환 animation 중이 아니다.
4. source 화면의 마지막 user Space가 아니다.
5. destination 화면에 현재 Space가 있다.

그 뒤 destination 화면의 **현재 Space ID**를 anchor로 삼아 다음 call shape을 scripting addition에 보낸다. [호출부](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L891-L922), [message packing](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/sa.m#L463-L481)

```c
scripting_addition_move_space_to_display(
    src_sid,
    destination_current_sid,
    source_was_active ? source_previous_sid : 0,
    source_was_active
);
```

Dock 안의 payload는 다음 작업을 한다. [Dock payload](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L460-L513)

```text
SLSCopyManagedDisplayForSpace(src_sid / destination_current_sid)
→ Dock의 private Space 객체와 display-space 객체 탐색
→ pattern scan으로 얻은 내부 moveSpace 함수 호출
→ DPDesktopPictureManager.moveSpace(_:toDisplay:displayUUID:) 호출
→ source가 active였다면 SLSManagedDisplaySetCurrentSpace와 Dock ivar 보정
```

Apple Silicon call ABI도 일반 함수 선언이 아니다. yabai는 `source`, `destination`, `destination UUID`를 `x0`~`x2`에 두고 Dock Spaces 객체를 `x20`에 둔 뒤 pattern으로 찾은 함수 주소를 호출한다. [arm64 call shim](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/arm64_payload.m#L1-L5)

목적지 순서도 공개 계약이 아니다. 호출부가 destination 화면의 **현재 Space**를 anchor로 주기 때문에 “화면만 동일”과 “저장된 local order까지 동일”은 다른 문제다. 정확한 순서가 필요하면 같은 화면 안의 `space --move`가 추가로 필요하고, 그 작업도 부분 SIP 해제 경로다.

## 2. 특정 화면에 일반 Space 생성

### SIP를 켠 경로: Mission Control AX

Hammerspoon은 Mission Control을 실제로 열고 다음 AX hierarchy를 찾는다.

```text
Dock
└─ mc.display (AXDisplayID == target CGDirectDisplayID)
   └─ mc.spaces
      └─ mc.spaces.add -- AXPress
```

구현은 `mc.spaces.add` 요소의 `doAXPress()`를 호출한다. 화면 전환을 완전히 숨길 수 없고, Dock AX tree가 만들어질 때까지 기다려야 한다. Hammerspoon은 이 모듈을 private API와 Accessibility hack의 조합인 experimental 기능으로 명시한다. [module caveat](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L2-L14), [add implementation](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L675-L738)

이 방식은 SIP 해제가 필요 없지만 Accessibility 승인이 필요하고, UI가 보이며, OS·언어·animation timing에 취약하다. 완료는 AXPress 반환값이 아니라 **목표 화면에 type `0` Space가 정확히 하나 늘어난 stable snapshot**으로 판정해야 한다.

### 조용한 private 경로: Dock scripting addition

yabai는 target display의 기존 Space ID 하나를 payload에 넘긴다. Dock payload는 그 ID에서 display UUID를 얻고, `ManagedSpace` 객체를 만든 뒤 pattern scan으로 찾은 내부 add 함수에 새 Space와 display-space 객체를 넘긴다. [caller guard](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L1062-L1071), [payload](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L542-L558)

```text
anchor_sid
→ SLSCopyManagedDisplayForSpace(anchor_sid)
→ [[ManagedSpace alloc] init]
→ display_space_for_display_uuid(uuid)
→ internal addSpace(new_space, display_space)
```

이 경로는 부분 SIP 해제가 필요하다. 더구나 현재 pinned HEAD의 변경 사항이 바로 **macOS 26.6 Apple Silicon용 add-space instruction pattern 수정**이다. 26.4 이상에 별도 byte pattern을 둔 코드가 patch-level ABI 불안정을 직접 보여준다. [26.6 pattern](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/arm64_payload.m#L175-L191)

### raw `SLSSpaceCreate`를 먼저 쓰지 않는 이유

26.6.2 wrapper와 `SLSBridgedSpaceCreateOperation`은 존재하고, bridged path는 결과 `spaceID`를 돌려주는 동기 operation이다. 그러나 `options` bit와 `values` dictionary의 현재 schema, 특히 **새 Space를 어느 managed display에 붙이는지**를 보여주는 현재 source가 없다. 잘못 생성하면 WindowServer와 Dock의 managed-space model이 어긋날 가능성도 배제할 수 없다.

반면 Dock AX add는 target display가 AX tree에 명시되고, 사용자가 직접 누르는 것과 같은 시스템 UI 경로다. 따라서 생성 probe는 raw create가 아니라 AX add를 먼저 사용한다. raw create는 이 UI 경로가 반복 실험에서 통과한 뒤에도 별도 reverse-engineering 과제로 남긴다.

## 3. 타사 창을 특정 일반 Space로 이동

### 판정

**네 작업 중 가장 현실적인 DEBUG 후보**다. 전체 Space를 건드리지 않고 한 WindowServer window ID의 membership만 바꾼다. yabai 7.1.25는 이 기능이 다시 SIP를 켠 채 동작한다고 기록한다. 다만 전부 private API이며 비동기 완료 계약도 없으므로 stable snapshot 검증이 필수다. [7.1.25 변경 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L12-L15)

### 현재 yabai의 1순위 call shape

yabai는 로드된 SkyLight Mach-O symbol table에서 아래 **local C++ symbol**을 직접 찾는다. `dlsym` 가능한 공개 ABI가 아니다. [symbol lookup](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/yabai.c#L143-L150)

```text
__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation
```

심볼이 있으면 private Objective-C 객체를 만들고 넘긴다. [implementation](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L665-L704)

```objc
Class cls = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
id op = [[cls alloc] initWithWindows:windowIDNumbers spaceID:destinationSID];
SLSPerformAsynchronousBridgedWindowManagementOperation(op);
```

함수 이름대로 비동기이고, 현재 yabai wrapper는 반환값으로 실제 membership 완료를 확인하지 않는다. Plugback probe는 호출 성공만으로 pass 처리하면 안 된다.

### 현재 fallback

bridged symbol이 없고 최신 macOS workaround가 필요하면 yabai와 Hammerspoon은 compat workspace ID를 잠깐 빌려 같은 destination SID에 창을 연결한다. [yabai fallback](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L675-L704), [Hammerspoon implementation](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces.m#L142-L199)

```c
SLSSpaceSetCompatID(cid, destination_sid, 0x79616265); // "yabe"
SLSSetWindowListWorkspace(cid, &window_id, 1, 0x79616265);
SLSSpaceSetCompatID(cid, destination_sid, 0);
```

구버전 경로는 다음 함수다.

```c
SLSMoveWindowsToManagedSpace(cid, window_id_array, destination_sid);
```

Hammerspoon은 source와 destination이 type `0`인지 확인하고, fullscreen/tiled Space는 기본적으로 거부한다. 이 guard를 Plugback도 그대로 유지해야 한다. [type guard](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces.m#L154-L181)

## 4. 삭제와 cleanup

### SIP를 켠 경로: Mission Control AX

Hammerspoon은 Space가 현재 active가 아니고 그 화면의 마지막 user Space가 아닌지 확인한 뒤, Mission Control의 해당 thumbnail에 `AXRemoveDesktop` action을 수행한다. [remove implementation](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L804-L882)

삭제 요청이 성공해도 Apple 문서상 그 Space의 창은 다른 Space로 이동할 수 있다. 따라서 자동 rollback은 **probe가 이번 실행에서 만든 정확한 type `0` SID이고, 창 membership이 비어 있으며, active가 아니고, 마지막 user Space가 아닐 때만** 삭제해야 한다.

### Dock scripting addition

yabai도 type `0`, not-last-user, not-animating guard 뒤 내부 remove 함수를 호출한다. Dock payload의 추정 call shape은 다음과 같다. [caller guard](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L1037-L1059), [payload](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L515-L540)

```c
remove_space_fp(space, display_space, dock_spaces, sid, sid);
```

이 함수 주소 역시 Dock binary pattern으로 찾고 Apple Silicon에서는 pointer authentication으로 다시 서명한다. 이름·signature·주소 어느 것도 Apple 계약이 아니다. [pattern lookup and signing](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L326-L362)

### raw `SLSSpaceDestroy`를 rollback에 쓰지 않는 이유

26.6.2에는 `SLSSpaceDestroy(cid, sid)`와 `SLSBridgedSpaceDestroyOperation.initWithSpaceID:`가 있다. 현재 wrapper는 hidden gate가 켜진 경우 async bridged destroy를, 아니면 `_CGSSpaceDestroy` fallback을 호출한다. 둘 다 완료 결과를 돌려주지 않는다.

삭제는 move보다 실패 비용이 크다. symbol 존재만 확인한 단계에서 pre-existing Space나 창이 있는 Space에 호출할 이유가 없다. 첫 prototype의 rollback은 Dock AX `AXRemoveDesktop`으로 제한하고, 그것도 **이번 run에서 AX add로 얻은 새 SID**에만 허용한다. AX cleanup을 검증할 수 없으면 빈 Space를 남겨 사용자가 Mission Control에서 지우도록 한다.

## 권한·SIP·안정성

| 경로 | Accessibility | Screen Recording | SIP | 주요 파손 지점 |
|---|---|---|---|---|
| Dock AX add/remove | 필요 | 불필요 | 켜도 됨 | `mc.*` AX tree, animation, user input |
| exported SLS Space move/create/destroy wrapper | topology 식별에는 필요 | 불필요 | **성공 여부 미검증** | hidden feature/entitlement gate, private ABI, async no-op |
| private window→Space bridged op | Plugback의 타사 AX 창 식별에는 필요 | 불필요 | 켜도 됨 | local Mach-O symbol, private class/selector, 비동기 의미 |
| compat-ID window→Space | 창 식별에는 필요 | 불필요 | 켜도 됨 | private SLS symbol과 magic workspace ID |
| whole-Space move/create/destroy SA | yabai 운용에 필요 | 이 작업 자체에는 불필요 | **부분 해제 필요** | Dock injection, OS별 instruction pattern, private ObjC layout/ABI |

Apple은 [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)로 현재 프로세스의 Accessibility 신뢰를 확인하라고 제공한다. prompt는 비동기이며 즉시 반환값을 바꾸지 않는다. 실행 전 `true`가 아니면 probe를 중단한다.

yabai도 Accessibility 승인 뒤 앱을 재시작해야 한다고 적고, Screen Recording은 window animation을 켤 때만 필요하다고 구분한다. 전체 Space command는 별도로 부분 SIP 해제를 요구한다. [requirements](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/README.md#L42-L66) Apple은 SIP가 시스템 앱과 보호 경로를 제3자 변경으로부터 지키는 보안 기능이라고 설명한다. [Apple: About System Integrity Protection](https://support.apple.com/en-us/102149)

안정성 평가는 낮다. 같은 yabai changelog에는 window→Space가 2024년 Sequoia에서 SIP 해제를 요구했다가 2026년 7.1.25에 다시 SIP-on이 된 이력과, 26.6에서 add-space pattern을 다시 고친 기록이 함께 있다. 이는 “현재 동작”과 “다음 macOS update에서도 동작”을 분리해야 한다는 직접 증거다. [2024년 Sequoia 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L134-L140), [2026년 및 26.6 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L7-L15)

App Store Review Guideline 2.5.1은 App Store 앱이 공개 API만 사용하도록 요구한다. 따라서 private write가 실제로 동작하더라도 Mac App Store 지원 기능으로 볼 수 없다. Plugback에서 실험한다면 non-sandboxed Developer ID Debug/direct build, OS-build allowlist, fail-closed가 전제다. [Apple App Review Guidelines 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements)

### 26.6.2 read-only presence check

실물 호스트에서는 어떠한 write도 하지 않고 `dlopen`/`dlsym`과 `NSClassFromString`만 실행했다. 다음 이름이 모두 존재했다.

```text
SLSMainConnectionID
SLSCopyManagedDisplaySpaces
SLSSpaceGetType
SLSCopySpacesForWindows
SLSCopyManagedDisplayForSpace
SLSManagedDisplayGetCurrentSpace
SLSMoveManagedSpaceToDisplayIndex
SLSSpaceCreate
SLSSpaceDestroy
SLSMoveWindowsToManagedSpace
SLSSpaceSetCompatID
SLSSetWindowListWorkspace
SLSManagedDisplaySetCurrentSpace
SLSBridgedMoveManagedSpaceToDisplayIndexOperation (Objective-C class)
SLSBridgedSpaceCreateOperation (Objective-C class)
SLSBridgedSpaceDestroyOperation (Objective-C class)
SLSBridgedMoveWindowsToManagedSpaceOperation (Objective-C class)
```

exported C wrapper 네 개는 `dlsym`으로 찾을 수 있었지만, `SLSWindowManagementClientOperationsEnabled`와 local C++ bridged performer는 찾을 수 없었다. 이 결과는 **symbol/class presence gate만 통과**했다는 뜻이다. 실제 write semantics와 SIP-on 성공 여부는 아직 검증하지 않았다.

## 앱 없는 Space identity와 수집 이벤트 추가 실측

2026-08-29에 내장 화면에서 새 비활성 type `0` Space를 만든 뒤 방문하지 않고 A 외장 화면으로 옮겼다. stable snapshot에서 새 Space가 A local order 2로 나타났고, 다시 내장 local order 2, 다시 A local order 2로 왕복하는 동안 같은 runtime SID와 `SLSSpaceCopyName` 값이 유지됐다. 앱·AX 표준 창이 없어도 같은 로그인 세션에서는 Space 자체의 화면 소속을 대응할 수 있다.

이 drag는 `NSWorkspace.activeSpaceDidChangeNotification`, 앱 activate/deactivate, `com.apple.expose.*` distributed notification과 Darwin notify를 내지 않았다. 반면 Dock application에 공개 AX notification을 등록하면 Mission Control 회차마다 다음 패턴이 반복됐다.

```text
AXSelectedChildrenChanged
AXUIElementDestroyed
AXSelectedChildrenChanged
```

열림 때 Dock tree에서 raw identifier `mc`를 실제로 확인한 뒤, 그 tree가 사라진 회차만 closed로 압축하면 상시 polling 없이 topology 수집을 다시 실행할 수 있다. `mc`와 Dock tree의 수명은 공개 계약이 아니므로 이 신호가 깨지면 다음 Space 방문·창 이동·앱 전환 수집으로 fail closed 해야 한다.

### 제품 watcher와 수동 복원 vertical slice

서명된 Debug 앱에서 A의 regular Space 세 개를 자동 후보에 담았다. 비활성 Space 하나를 A에서 내장 화면으로 옮기고 Mission Control을 닫자 후보가 3개에서 2개로 줄었고, 다른 내장 Space를 A로 옮긴 다음 닫자 새 opaque name을 포함한 3개로 바뀌었다. 방문이나 앱 창 없이도 Dock AX 닫힘 신호 뒤 stable snapshot이 Space 자체의 화면 소속을 갱신했다.

A를 분리해 후보를 확정하고 B를 사용한 뒤 A를 다시 연결한 회차에서는 macOS가 저장된 비활성 Space 두 개를 같은 SID와 opaque name으로 A에 스스로 다시 붙였다. Plugback relocation 호출은 0회였고 A에 저장하지 않은 별도 Space는 내장 화면에 남았다. 따라서 이 회차는 native 재귀속과 잘못된 화면 적용 방지는 증명하지만 visible drag 경로 성공 횟수로 세지 않는다.

visible drag를 결정적으로 시험하려고 A에서 프로필을 다시 저장한 뒤 저장 대상 Space `dbc7…`/`2f5f…`를 내장 화면으로 옮겼다. 수동 복원에서 planner move 1회와 relocator 1회가 실행됐고, Mission Control이 보인 뒤 같은 SID·opaque name의 Space가 A local order 3으로 돌아왔다. 복원 전후 다른 내장 regular Space의 소속은 유지됐고, 사후 stable snapshot 두 read의 topology와 window membership이 일치했다.

## 최소 DEBUG-only 실기기 probe

제품 모델·저장 형식·Release binary를 바꾸지 않는다. 기존 `SpaceReader`와 AX→WindowServer join을 observer로 재사용하고, 새 UI나 일반화된 mutation abstraction은 만들지 않는다.

### 준비

1. 두 화면에 각각 type `0` Space가 하나 이상 있고 `NSScreen.screensHaveSeparateSpaces == true`인지 확인한다.
2. 사용자가 source 화면에 **빈 일반 Space 하나를 수동으로 새로 만든다**. 이 sacrificial SID는 inactive여야 하고 source에는 그것을 제외한 user Space가 하나 이상 남아야 한다. 기존 사용자 Space를 첫 mutation 대상으로 쓰지 않는다.
3. window-move 단계용 test window 하나만 고른다. source/target membership이 각각 단일 type `0`이어야 한다. fullscreen·Split·sticky·다중 membership이면 중단한다.
4. stable snapshot 두 회로 모든 기존 Space의 SID, opaque name, display, local order, type, current 여부와 모든 joined window membership을 메모리에 기록한다.
5. AX 신뢰가 `true`이고 Mission Control·display animation·화면 재구성이 진행 중이 아니어야 한다.
6. 실행마다 최대 8초, stable snapshot 두 회만 기다린다. 무한 retry는 없다.

### 단계 A — visible Mission Control drag, SIP ON

실기기에서 이미 한 번 성공한 동작을 빈 sacrificial Space로 격리해 자동화한다.

1. Mission Control을 열고 Dock AX tree가 stable해질 때까지 기다린다.
2. `mc.display.AXDisplayID`로 source와 destination display group을 고정한다.
3. source의 `mc.spaces.list` child를 snapshot의 `localOrder`와 대조한다. child 수/type/order가 맞지 않으면 drag하지 않는다.
4. source thumbnail frame 중심에서 destination Spaces bar의 끝 위치까지 mouse-down → drag → mouse-up을 한 번 합성한다. drag 중 실제 mouse 위치나 AX tree가 예상과 달라지면 mouse-up만 보내고 중단한다.
5. Mission Control을 닫고 같은 SID·opaque name의 display association과 모든 membership을 stable snapshot으로 검증한다.
6. 정확히 같은 SID를 source bar로 한 번 역-drag하고 baseline 복귀를 검증한다.

**pass**: 3/3에서 같은 SID가 왕복하고 다른 regular/type `4`의 display·상대 순서·membership 변화가 매번 동일하며, 최종 snapshot이 baseline과 같다.

**fail**: AX child와 snapshot mapping 불일치, 잘못된 thumbnail, no-op, 두 개 이상 Space의 예기치 않은 변화, 사용자 입력 충돌, 역-drag 뒤 baseline 불일치.

type `4`가 함께 이동하는 것은 이번 실기기 관찰과 정확히 같은 결과일 때만 허용한다. “따라올 것”이라고 미리 가정해 target을 넓히지 않는다. 첫 자동 prototype은 창이 없는 regular sacrificial Space만 쓴다.

### 단계 B — same-Space relocation raw probe, SIP ON 유지

visible drag와 같은 결과를 조용한 private wrapper가 낼 수 있는지 별도로 판정한다. Dock injection이나 Space create/destroy를 하지 않고, 사용자가 방금 만든 빈 Space 하나만 움직인다.

1. `SLSMoveManagedSpaceToDisplayIndex`를 `dlsym`하고 현재 build allowlist와 signature를 확인한다.
2. destination identifier는 같은 baseline의 `SLSCopyManagedDisplaySpaces` 결과에서 가져온다.
3. destination 끝에 넣는 단일 가설로 `index = destination.spaces.count`를 사용해 wrapper를 **한 번** 호출한다. 다른 index로 자동 재시도하지 않는다.
4. 같은 SID가 destination으로 옮겨졌는지 stable snapshot으로 확인한다. association 성공과 local-order 성공은 따로 기록한다.
5. source identifier와 저장한 `sourceLocalOrder - 1`로 역호출을 한 번 수행한다.
6. baseline으로 돌아온 첫 run이 확인된 뒤에만 3회까지 반복한다.

**pass — association**: 3/3에서 같은 SID·opaque name이 destination으로 갔다가 source로 돌아오고, 다른 Space의 상대 순서·current 상태·window membership이 유지된다.

**pass — order**: association pass에 더해 destination에서 매번 요청한 끝 위치, source에서 매번 원래 local order로 돌아온다.

**fail**: no-op/timeout, SID 교체, 잘못된 display, 관련 없는 Space 순서·current 상태 변화, Dock relaunch, desktop picture 이상, 역호출 뒤 baseline 불일치 중 하나라도 발생한다.

association만 통과하고 order가 실패하면 “Space를 화면으로 돌리기”는 후보가 되지만 정확한 순서 복구는 별도 미해결이다. 첫 역호출이 실패하면 자동 삭제하지 않는다. 빈 sacrificial Space를 그대로 두고 snapshot과 수동 Mission Control 정리 방법을 출력한다.

### 단계 C — window→Space, SIP ON

1. test window의 source SID와 frame을 기록한다.
2. bridged symbol/class가 모두 있으면 private bridged operation을 **한 번** 호출한다. 없으면 compat-ID 세 호출을 한 번 수행한다.
3. target SID 하나만 membership이 될 때까지 관찰한다.
4. 같은 경로로 source SID에 되돌린 뒤 frame도 AX로 복원한다.
5. 3회 반복한다.

**pass**: 3/3에서 target→source가 각각 8초 안에 안정화되고, window ID가 유지되며, 다른 window/Space membership과 topology가 바뀌지 않는다.

**fail**: 심볼·class·target type 불일치, ambiguous membership, timeout, 관련 없는 상태 변화 중 하나라도 발생한다.

### 단계 D — AX create/remove, SIP ON

1. Hammerspoon과 같은 Dock AX tree에서 target display의 `mc.spaces.add`를 찾아 `AXPress` 한 번만 수행한다.
2. target display에 새 type `0` SID가 정확히 하나 생겼는지 확인한다.
3. 기존 Space를 active로 만든 뒤 새 Space가 empty·inactive·not-last인지 다시 확인한다.
4. 새 thumbnail의 `AXRemoveDesktop`을 한 번 수행하고 SID가 사라질 때까지 관찰한다.

**pass**: create 뒤 `+1`, remove 뒤 baseline topology로 복귀하고 기존 SID·membership이 모두 유지된다.

**fail**: AX tree/action 부재, 새 SID가 0개 또는 2개 이상, 잘못된 display/type, cleanup 뒤 baseline 불일치.

### 단계 E — 동등한 재구성 vertical slice

단계 C와 D가 각각 통과한 뒤에만, Space 이동이 실패할 때의 현실적 fallback을 한 번 조합한다.

1. target display에 AX로 새 type `0` Space 하나를 만든다.
2. test window 하나를 새 SID로 옮긴다.
3. 새 Space를 방문해 저장 frame을 복원한다.
4. window를 original SID로 되돌리고 frame을 복원한다.
5. 새 SID가 empty·inactive·not-last임을 다시 확인한 뒤 AX로 삭제한다.

**pass**: 3/3에서 목표 화면에 equivalent regular Space와 창이 생기고 frame이 복원되며, rollback 뒤 baseline으로 돌아온다.

**fail**: 생성·membership·frame 중 하나라도 잘못되거나, cleanup 뒤 baseline이 다르다.

이 단계가 통과해도 same-Space 복구가 아니다. 새 SID가 생기고 원래 내장 Space는 남는다. 여러 저장 Space의 local order는 AX add가 append하는 현재 관찰값을 별도 3/3 gate로 검증해야 한다.

### yabai는 선택적 reference oracle일 뿐이다

이미 부분 SIP가 해제된 전용 lab이라면 pinned yabai `dd84572`로 sacrificial Space의 `--display` 왕복을 비교할 수 있다. Plugback을 위해 SIP를 해제하거나, yabai scripting addition을 제품 dependency로 추가하지 않는다. oracle이 성공해도 “Dock 주입으로 가능”만 확인하며 raw wrapper의 성공 근거가 되지 않는다.

### rollback 우선순위

실패해도 다음 순서만 실행한다.

1. test window를 기록한 original SID로 되돌리고 frame을 복원한다.
2. visible drag가 성공했다면 stable AX mapping으로 같은 sacrificial SID만 source로 한 번 역-drag한다. mapping이 모호하면 자동 rollback을 시도하지 않는다.
3. raw move가 성공했다면 sacrificial SID에만 저장한 source display/index 역호출을 한 번 수행한다. 실패하면 다른 index나 다른 Space를 추측하지 않는다.
4. probe가 AX add로 만든 정확한 SID만 자동 삭제 대상으로 한다. 다른 pre-existing SID와 raw-move 대상은 절대 raw destroy하지 않는다.
5. 생성한 Space가 empty·inactive·type `0`이고 해당 화면의 마지막 user Space가 아닐 때만 `AXRemoveDesktop`을 수행한다.
6. 어느 조건이든 확인할 수 없으면 자동 cleanup을 멈추고 current snapshot을 출력한다. 빈 임시 Space는 데이터 손실보다 안전하므로 남겨 수동으로 정리한다.

## Plugback 판단

1. **가장 작은 제품 fallback은 사용자에게 수동 drag를 안내하고 Plugback이 결과만 검증하는 것**이다. 이번 실기기에서 같은 SID와 fullscreen 상태까지 보존됐다.
2. 자동화를 원하면 단계 A의 visible drag를 먼저 격리 검증한다. 사용자에게 보이고 input 충돌 위험이 있지만, 성공한 시스템 UI 동작을 그대로 재현하며 SIP를 낮추지 않는다.
3. 단계 B raw wrapper는 조용한 자동화를 위한 별도 lab이다. 통과해도 OS build allowlist와 3/3 회귀 gate 없이는 켜지 않는다.
4. A/B가 실패하면 C와 D를 독립적으로 검증한 뒤 E의 equivalent reconstruction만 고려한다. Mission Control이 보이는 UX와 원래 내장 Space가 남는 점을 사용자 계약에 명시해야 한다.
5. raw create/destroy, Dock injection, 부분 SIP 해제는 Plugback 배포 요구사항으로 채택하지 않는다.
6. 어떤 private write도 OS build가 바뀌면 다시 gate를 통과하기 전까지 fail closed 한다. 실제 A→B→A gate에서는 먼저 빈 sacrificial Space, 그다음 test window 하나가 든 sacrificial Space 순으로 통과시킨다.
