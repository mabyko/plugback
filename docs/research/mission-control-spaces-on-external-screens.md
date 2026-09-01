# 외장 화면의 Mission Control Space 복원 조사

조사일: 2026-08-27

범위: 「화면마다 개별 Spaces」가 켜진 맥북에서 외장 화면의 일반 Desktop Space 2개 이상을 쓰는 경우

상태: 조사 노트. Apple이 보장한 사실, 추론, 로컬 측정, 외부 사례를 구분한다.

후속 결정과 구현 단계는 [활성 Space 기반 복원 구현 계획](../ACTIVE_SPACE_RESTORE_PLAN.md)에 있다.

> **현재 제품 결정(2026-09-01):** 제품은 Mission Control을 자동 조작하지 않는다. read-only로 잔류 Space와 출발·목적 화면을 안내하고, 사용자가 옮긴 뒤 표준 창 위치만 자동 복원한다.

## 결론

공개 API만으로는 `외장 화면 × Desktop Space × 다른 앱 창` 구성을 식별하거나 복원할 수 없다. 공개 API가 알려주는 것은 개별 Spaces 설정 여부, 창의 전역 좌표·크기, 활성 Space 포함 여부 같은 조각뿐이다. 특정 Space의 공개 식별자, Space와 화면의 매핑, 다른 앱 창을 지정한 Space로 보내는 수단은 없다.

따라서 현재 제품의 안전한 경계는 다음과 같다.

1. macOS 또는 사용자가 Space를 외장 화면에 배치한다.
2. 그다음 Plugback이 대상 앱의 창 좌표·크기를 복원한다.

`Desktop 1`, `Desktop 2`를 프로필 키로 저장하거나, 연결 직후 Mission Control을 자동 조작하는 기능은 v1에 넣지 않는다. 먼저 아래 실기기 행렬로 macOS의 분리·재연결 동작을 확인해야 한다.

## 시나리오

연결 전 상태를 다음처럼 둔다.

```text
내장 화면: I1
외장 화면: E1 — 앱 A
           E2 — 앱 B
```

사용자가 관찰한 것은 외장 화면 분리 뒤 `E1`, `E2`로 보이던 작업 공간이 내장 화면의 `Desktop 2`, `Desktop 3`처럼 나타나고, 재연결 뒤 이를 외장 화면으로 다시 옮길 수 있다는 동작이다. 여기서 UI의 `Desktop 2`라는 이름만으로는 그것이 기존 `E1`의 정체성을 유지한 것인지, 창만 다른 Space로 합쳐진 것인지, 목록이 다시 번호 붙은 것인지 구별할 수 없다.

## Apple이 문서화한 사실

### 화면별 Space

- 「Displays have separate Spaces」를 켜면 화면마다 별도 Space 집합을 둔다. [`NSScreen.screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces)는 이 설정을 `Bool`로 읽는다. 이 값이 `true`여도 실제 화면이나 Space가 여러 개 있다는 뜻은 아니다. [Apple의 Desktop & Dock 설정 안내](https://support.apple.com/en-ie/guide/mac-help/mchlp1119/mac)
- 두 번째 화면에서 Mission Control을 열면 그 화면에서 쓰는 창과 Space만 보인다. [Apple의 Mission Control 안내](https://support.apple.com/en-ie/guide/mac-help/mh35798/mac)
- 「Automatically rearrange Spaces based on most recent use」가 켜지면 최근 사용 순서에 따라 Space가 재정렬된다. 따라서 이 설정이 켜진 환경의 `Desktop 2`는 고정된 정체성으로 쓸 수 없다. 마지막 문장은 문서에 근거한 추론이다. [Apple의 Desktop & Dock 설정 안내](https://support.apple.com/en-ie/guide/mac-help/mchlp1119/mac)

### 사용자가 옮길 수 있다고 공식 설명된 것

- Mission Control에서 **앱 창**을 원하는 Space 썸네일로 드래그할 수 있다.
- Dock의 앱 옵션에는 `All Desktops`, `This Desktop`, `Desktop on Display [number]`, `None`이 있다. `Desktop on Display [number]`도 특정 번호의 Space를 지정하는 API가 아니라 특정 화면의 현재 Space에 앱을 할당하는 사용자 설정이다.
- Space를 삭제하면 그 안의 창은 다른 Space로 이동한다.

이 세 동작은 [Apple의 여러 Spaces 사용 안내](https://support.apple.com/en-ie/guide/mac-help/mh14112/mac)에 명시돼 있다. 반면 일반 Desktop Space **썸네일 자체를 화면 사이로 드래그하는 절차**는 현재 Apple 사용자 설명서에 없다. 실제 UI에서 가능하더라도 공개된 동작 계약으로 볼 수 없다.

## Apple이 문서화하지 않은 부분

Apple의 현재 사용자 설명서와 개발자 문서는 다음을 설명하지 않는다.

- 외장 화면을 분리할 때 그 화면의 Space 집합이 보존, 이동, 병합, 삭제 중 무엇을 하는지
- Space와 그 안의 창이 함께 이동하는지, 창만 이동하는지
- 같은 외장 화면을 다시 연결하면 원래 화면으로 자동 복귀하는지
- 분리 중 잠자기·로그아웃·재시작을 거쳐도 같은지
- Space의 내부 정체성, UI 이름, 순서, 화면 소속이 얼마나 오래 유지되는지
- 일반 Desktop Space 썸네일을 화면 사이로 옮기는 UI가 버전별로 보장되는지
- 일반 Desktop Space와 전체 화면·Split View Space의 분리·재연결 규칙이 같은지

그러므로 “외장 화면의 Desktop 1·2가 내장 화면의 Desktop 2·3으로 내려온다”와 “재연결하면 원래 화면으로 돌아온다”는 현재로서는 macOS 계약이 아니라 실측할 가설이다.

## 공개 API가 할 수 있는 일과 없는 일

| 계층 | 공개 API로 가능한 일 | Space 복원에 모자란 점 |
|---|---|---|
| AppKit 화면 | [`NSScreen.screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces)로 개별 Spaces 설정 조회 | Space 개수, ID, 순서, 화면 소속을 주지 않음 |
| AppKit 창 목록 | [`NSWindow.windowNumbers(options:)`](https://developer.apple.com/documentation/appkit/nswindow/windownumbers%28options%3A%29)에 `allApplications`와 `allSpaces`를 함께 주면 모든 앱·Space의 보이는 창 번호를 평평한 목록으로 열거 | 어느 창이 어느 Space에 속했는지 주지 않음 |
| 자기 앱의 창 | [`NSWindow.isOnActiveSpace`](https://developer.apple.com/documentation/appkit/nswindow/isonactivespace)로 활성 Space 포함 여부 조회. [`canJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces), [`moveToActiveSpace`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/movetoactivespace)로 자기 `NSWindow`의 정책 지정 | 다른 앱 창에 적용할 수 없고, 대상 Space ID나 화면을 지정하지 못함 |
| Accessibility | PID로 다른 앱의 AX 트리를 열고, `AXWindows`·[`AXPosition`](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute)·[`AXSize`](https://developer.apple.com/documentation/applicationservices/kaxsizeattribute)를 읽는다. 앱이 허용하면 [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)로 위치·크기를 설정 | 공개 표준 속성에 Space ID·Space 순서·Space 화면 소속이 없음. 좌표 설정이 Space 소속에 주는 부수효과도 문서화되지 않음 |
| Core Graphics 창 목록 | [`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29)로 현재 사용자 세션의 창 번호, 소유 PID, bounds 등을 조회 | 현재 지원되는 [필수 키](https://developer.apple.com/documentation/coregraphics/required-window-list-keys)와 [선택 키](https://developer.apple.com/documentation/coregraphics/optional-window-list-keys)에 쓸 수 있는 Space 매핑이 없음 |

Core Graphics에는 예전에 창의 workspace ID를 담던 [`kCGWindowWorkspace`](https://developer.apple.com/documentation/coregraphics/kcgwindowworkspace)가 있었지만 macOS 10.8부터 “No longer supported”로 폐기됐다. 현재 SDK에서는 Swift 코드가 이 상수를 참조하면 컴파일 오류가 난다. 창 bounds와 화면 frame의 교차로 현재 좌표상 화면을 추정할 수는 있지만, 이것은 Space 정체성이나 과거 화면 소속이 아니다.

### 공개 API에 대한 추론

공개 API를 조합해 다음 정도는 알 수 있다.

- 화면이 연결·분리됐는가
- 개별 Spaces 설정이 켜졌는가
- 다른 앱의 표준 창이 어떤 전역 좌표·크기를 가졌는가
- 모든 Space를 통틀어 창 번호가 더 존재하는가

그러나 평평한 창 목록과 좌표만으로 `창 W는 외장 화면의 E2에 있었다`를 복원할 수 없다. `Desktop 2` 같은 순번도 자동 재정렬 옵션 때문에 키가 될 수 없고, 옵션을 꺼도 Apple이 안정성을 보장한 공개 식별자가 없다.

## 로컬 측정: 공개 API

측정 환경은 macOS 26.5.2, Xcode 26.6, macOS SDK 26.5다. 모두 읽기 전용으로 확인했다.

- 정식 AppKit 애플리케이션 컨텍스트에서 다시 측정하니 화면은 2개였고 `NSScreen.screensHaveSeparateSpaces == true`였다. 이전의 단독 CLI 초기 측정값 `false`는 이 결과로 대체한다. 설정·Space·창·로그인 상태·케이블은 바꾸지 않았다.
- `NSWindow.windowNumbers(options: [.allApplications])`는 활성 Space 범위 48개, `allSpaces`까지 더하면 52개를 반환했다. 전체 Space 열거가 실제로 더 넓은 집합을 주지만 Space별 묶음은 주지 않는다는 확인이다. 창 개수는 실행 중인 프로세스에 따라 달라지는 순간값이다.
- `CGWindowListCopyWindowInfo(.optionAll, ...)`의 연속 측정은 303~304개 창 딕셔너리를 반환했고 `kCGWindowWorkspace` 문자열 키는 한 건도 없었다. 창 개수는 실행 중인 프로세스 때문에 변할 수 있으므로 의미 있는 결과는 workspace 키가 없었다는 점이다.
- SDK의 `AXAttributeConstants.h`에는 `AXPosition`, `AXSize`, `AXWindows`가 있지만 표준 `Space` 또는 `Workspace` 속성은 없다. 위치·크기가 일반적으로 창에서 쓰기 가능하다는 설명도 헤더에 있다.

이 측정은 API 표면만 확인한다. 개별 Spaces는 켜져 있었지만 실제 분리·재연결은 하지 않았으므로 외장 화면 Space의 이관 동작에 대한 증거는 아니다.

## 로컬 측정: private WindowServer 계층

현재 시스템의 SkyLight를 `dlopen`/`dlsym`으로 읽기 전용 조사한 결과, 다음 private 심볼이 export돼 있었다.

- 읽기: `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`, `SLSCopyManagedDisplayForSpace`, `SLSManagedDisplayGetCurrentSpace`, `SLSSpaceGetType`, `SLSSpaceCopyName`, `SLSCopyWindowsWithOptionsAndTags`
- 변경: `SLSAddWindowsToSpaces`, `SLSRemoveWindowsFromSpaces`, `SLSMoveWindowsToManagedSpace`

`SLSCopyManagedDisplaySpaces`의 로컬 반환값에는 화면별 배열과 `uuid`, `id64`, `ManagedSpaceID` 같은 내부 필드가 있었다. 실제 값은 기록하지 않았다. 이는 WindowServer 내부에 Space 정체성과 화면 매핑이 존재한다는 로컬 관찰일 뿐이다. 공개 헤더·문서·호환성 계약이 없고, 이 ID가 재연결·재시작 뒤에도 안정적인지도 아직 확인하지 않았다.

특히 `SLSMoveWindowsToManagedSpace`는 창을 Space로 보내는 것과 Space 자체를 다른 화면으로 옮기는 것을 같게 만들지 않는다. 전체 Space 이동은 별도 문제다.

### Plugback 앱 신원 실기기 게이트

같은 날 Plugback Debug 앱의 기존 서명·bundle ID에서 read-only probe를 실행했다.

- 외장 Desktop 4가 비활성일 때 Finder와 Zed를 배치하자 그 Space의 raw 창 수는 `5 → 8`로 늘었지만 두 앱의 AX 표준 창은 열거되지 않았다.
- Desktop 4를 활성화하자 두 앱 모두 frame, `_AXUIElementGetWindow`, 단일 type `0` membership이 연결됐다.
- Zed native fullscreen Space는 비활성일 때도 별도 type `4`로 보였지만 Zed AX 창은 없었다. 활성화하자 `AXFullScreen=true`, frame readable, 단일 type `4` membership으로 연결됐다.
- 연속 두 snapshot은 동일했고 재빌드 뒤에도 Accessibility 신뢰가 유지됐다.
- 외장 일반 Space를 번갈아 전환한 9회에서는 `activeSpaceDidChangeNotification` 직후의 current Space가 실제 전환과 일치했고, 매번 즉시 연속 조회한 두 snapshot도 같았다.
- 이후 내장 화면에 일반 Space 하나와 Slack native fullscreen Space 하나를 추가하자 내장 배열은 type `0` 3개 + type `4` 1개가 됐다. fullscreen 해제 뒤 type `4`가 사라졌고, 외장 두 일반 Space의 global order는 `3/4 → 5/6 → 4/5`로 변했다. 화면 안 순서·화면 소속·익명화한 non-empty name은 전 과정에서 그대로 유지됐다.
- 같은 포트 재연결 3회에서도 외장 화면과 두 일반 Space의 name·local order는 재연결 알림 순간부터 유지됐다. 두 번째 회차의 raw membership은 알림 순간 `6/0`, 약 2초 뒤 `25/5`였고 이후 표본에서 같았다. 세 번째 회차는 알림 순간 `4/1`, 다음 1초대 표본에서 `23/5 → 25/5`로 안정됐다. 연속 두 즉시 snapshot이 같아도 macOS의 창 이관까지 끝났다는 뜻은 아니며, 1.5초 후행 대기가 유효한 후보로 남았다.
- 두 번째 분리 상태에서는 외장 첫 Space의 name이 사라지고 그 창들이 내장 현재 Space에 합쳐진 것으로 보였다. 외장 두 번째 Space는 같은 name을 유지한 채 내장 local order `4`의 독립 Space로 남았고, 15초 뒤에도 같았다. 재연결하면 두 Space 모두 원래 외장 화면으로 복귀했다.
- 위 Space 전환 9회와 같은 포트 재연결 3회는 “Spaces를 최근 사용 내역에 따라 자동으로 재정렬”이 켜진 조건이었다. ON 조건에서는 방문 순서를 바꿔도 외장 두 Space의 name·local order가 유지됐다.
- 자동 재정렬 OFF 뒤에도 외장 두 Space를 왕복한 알림의 current 상태가 실제 전환과 일치했고, 복귀 뒤 name·local order가 그대로였다. 같은 포트 3회 identity와 ON/OFF 이벤트 게이트는 통과했다.

따라서 비활성 Space의 topology와 raw membership 감지는 가능하지만, 제품이 이동에 사용하는 AX 표준 창은 활성 Space에서만 얻을 수 있다. 후속 구현은 비활성 one-pass 복원이 아니라 Space 활성화 시 복원으로 제한한다.

## Plugback에 미치는 영향

현재 프로필은 화면 하나에 앱별 `unitRect` 하나만 저장한다. Space나 창 정체성은 없다. [`TargetApp`](../../Sources/PlugbackKit/Model.swift#L93-L110)

- 저장은 앱별 첫 표준 창 하나만 고른다. [`CaptureEngine`](../../Sources/PlugbackKit/CaptureEngine.swift#L17-L40)
- 복원은 대상 화면에 창이 없으면 그 앱의 첫 이동 가능한 표준 창을 어디서든 고른다. 코드에는 “macOS가 창을 내장으로 옮겨둔다”는 가정이 있지만 Apple 문서가 보장한 동작은 아니다. [`RestoreEngine`](../../Sources/PlugbackKit/RestoreEngine.swift#L160-L177)
- 실물 이동은 AX의 위치·크기 설정뿐이다. [`AXWindowGateway`](../../Sources/PlugbackKit/AXWindowGateway.swift#L70-L79)
- 화면 변화는 기본 1.5초 debounce 뒤 안정됐다고 보고 처리한다. Space 이관 완료를 알려주는 공개 이벤트는 확인되지 않았으므로, macOS의 이관이 더 오래 걸리면 자동 복원과 경합할 수 있다. [`DisplayWatcher`](../../Sources/PlugbackKit/DisplayWatcher.swift#L34-L36)

따라서 같은 앱의 창 두 개를 외장 화면 E1·E2에 하나씩 두면 현재 모델은 둘을 표현할 수 없다. 앱이 서로 달라도 AX 좌표 이동만으로 원래 Space 소속이 복원된다고 보장할 수 없다. 이 문제는 좌표 필드에 `spaceIndex` 하나를 더하는 것으로 해결되지 않는다. 공개된 안정 식별자와 이동 수단이 모두 없기 때문이다.

## 비공식 사례와 대안

이 절은 Apple 계약의 근거가 아니라 구현 위험과 실험 가설을 잡기 위한 참고다.

### 좁은 조건의 현장 보고

한 사용자의 [다중 화면 Spaces 관찰 기록](https://gist.github.com/aoberoi/1100eca269fac423faa8ad218462b44e)은 외장 화면을 주 화면으로 두고, 내장 화면에는 Space 하나만 두며, 외장 화면의 첫 Space를 비워둔 조건에서 다음을 관찰했다고 적었다.

- 분리 시 외장 화면의 2번째 이후 Space와 창이 내장 화면으로 이동
- 같은 화면 재연결 시 2번째 이후 Space가 외장 화면으로 자동 복귀
- 내장 화면에 Space가 여러 개면 합쳐지는 순서가 달라짐

기록 자체가 “작성 중”이고 외장 화면 첫 Space에 창이 있을 때를 미해결로 남겼다. OS 버전·반복 횟수도 충분하지 않아 제품 계약으로 쓰면 안 된다. 다만 사용자가 본 “맥북으로 내려왔다가 다시 외장 화면으로 옮긴다”는 현상이 화면의 주/보조 설정, 첫 Space의 창, 내장 Space 개수에 따라 달라질 수 있다는 실험 가설은 준다.

### private API

private SkyLight 읽기를 쓰면 Space와 화면의 내부 매핑을 관찰하는 실험 도구는 만들 수 있다. 그러나 직접 배포 앱이라도 여기에 기대면 OS 업데이트 때의 파손, 반환 형식 변경, 사용자 보안 설정과 신뢰 비용을 모두 떠안는다.

Space 자체를 화면 사이로 옮기는 자동 변경은 더 위험하다. [yabai의 현재 소스](https://github.com/asmvik/yabai/blob/master/src/space_manager.c)는 전체 Space 이동을 Dock scripting addition으로 처리하고, 화면의 마지막 사용자 Space는 이동하지 못하게 막는다. [yabai 문서](https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc)는 `space --display`에 부분적인 SIP 비활성화가 필요하다고 명시한다. Plugback이 일반 사용자에게 요구할 수 있는 보안·설치 비용이 아니다.

### Mission Control UI 자동화

[Hammerspoon의 `hs.spaces` 문서](https://www.hammerspoon.org/docs/hs.spaces.html)는 private API와 Dock Accessibility 조작의 결합을 실험 기능으로 표시한다. Mission Control이 화면에 완전히 나타난 뒤에만 AX 요소가 생기므로 가변 지연이 필요하고, 시각 전환도 숨길 수 없다고 설명한다. 실제 복원 도구인 [`restore-spaces`](https://github.com/tplobo/restore-spaces/blob/development/README.md)도 macOS 14.5와 15.0에서 창의 Space 이동이 깨진 사례를 기록한다.

마우스 좌표로 Space 썸네일을 끌어 화면 사이로 옮기는 자동화는 이보다 더 약하다. 화면 배치·해상도·애니메이션·사용자 입력·Mission Control UI 변경에 모두 의존한다. 기본 복원 경로에는 두지 않는다.

## 후속 실측 전의 최소 v1 권장안

아래는 Plugback 앱 신원 프로브를 만들기 전의 보수적 결론이다. 이후 활성·비활성 AX 대조가 끝나면서 [활성 Space 기반 복원 구현 계획](../ACTIVE_SPACE_RESTORE_PLAN.md)으로 대체됐다. private write를 금지하고 `Desktop N`을 저장하지 않는 안전선은 그대로다.

1. **Space 복원 모델을 추가하지 않는다.** `Desktop 1/2` 순번, private UUID, 창 제목을 프로필 키로 저장하지 않는다.
2. **기존 수동 복원 모드를 재사용한다.** 여러 Space를 쓰는 사용자는 외장 화면 연결 → Mission Control에서 Space 정리 → Plugback 수동 복원 순서로 사용한다. 새 모드나 새 설정은 필요 없다.
3. **개별 Spaces 설정만으로 자동 복원을 전부 끄지 않는다.** Apple 헤더가 명시하듯 설정이 켜져 있어도 Space가 여러 개라는 뜻은 아니다.
4. **실기기 측정 전 자동 Mission Control 조작을 만들지 않는다.** 먼저 아래 행렬로 macOS의 실제 이관·복귀 타이밍과 Space 정체성 유지 여부를 확인한다.
5. 후속 다리 역할이 꼭 필요하면 shipping 기능이 아니라 **실험실의 private 읽기 전용 감지**부터 검토한다. 확실한 경우에만 자동 복원을 잠시 멈추고 “Mission Control에서 Space를 외장 화면으로 옮긴 뒤 복원” 안내를 보여준다. Space를 private API로 직접 변경하지 않는다.

## 실기기 실험 행렬

### 준비

- 「Displays have separate Spaces」 켬. 변경 뒤 로그아웃/로그인.
- 자동 재정렬은 각 행의 조건에 맞춤.
- 내장 `I1`, 외장 `E1`, `E2`, `E3`에 서로 다른 배경과 제목이 분명한 창을 둔다. UI 번호 대신 배경·창 조합으로 Space를 추적한다.
- 분리 전, 분리 5초·15초 뒤, 재연결 1.5초·5초·15초 뒤 Mission Control 상태를 기록한다.
- Space 썸네일의 화면 소속·순서, 창 소속, 활성 Space, 창 bounds를 함께 기록한다. 가능하면 private SLS ID는 테스트 로그에서만 해시해 전후 동일성 비교에 쓴다.
- 현재 지원 macOS와 가장 오래 지원할 macOS에서 핵심 1·3·6번을 각각 3회 반복한다.

| 번호 | 조건 | 확인할 질문 |
|---|---|---|
| 1 | 외장 화면이 주 화면, 내장 Space 1개, 외장 `E1` 비움, `E2/E3`에 창. 자동 재정렬 끔. 같은 포트로 즉시 재연결 | 현장 보고처럼 `E2/E3`가 함께 내려오고 자동 복귀하는가? 내부 ID도 유지되는가? |
| 2 | 1번과 같되 `E1`에도 창을 둠 | 첫 Space는 병합되는가? 재연결 때 창과 Space가 다시 분리되는가? |
| 3 | 내장 `I1/I2`, 외장 `E1/E2`. 자동 재정렬 끔 | 내려온 Space의 순서와 화면 소속이 어떻게 합쳐지고 복귀하는가? `Desktop N` 번호가 어떻게 바뀌는가? |
| 4 | 3번에서 자동 재정렬 켬. 분리 전 방문 순서를 의도적으로 바꿈 | 최근 사용 순서가 표시 순서뿐 아니라 재연결 화면 소속에도 영향을 주는가? |
| 5 | 분리 상태에서 잠자기/깨우기, 다음 회차에는 로그아웃 또는 재시작 후 재연결 | Space 내부 ID·화면 소속·자동 복귀가 세션 경계를 넘는가? |
| 6 | 같은 앱의 표준 창 2개를 외장 `E1/E2`에 하나씩 둠. Space를 수동 정리한 뒤 Plugback 복원 | 현재 “앱별 첫 창” 선택이 어느 창을 옮기는가? Space가 흐트러지거나 다른 창을 덮는가? |
| 7 | Mission Control에서 일반 Desktop Space 썸네일 전체를 다른 화면으로 직접 드래그. 일반 Space와 전체 화면 Space를 각각 시도 | UI가 실제로 허용하는 이동 단위와 제한은 무엇인가? 마지막 사용자 Space도 옮길 수 있는가? |

추가 변형은 같은 물리 화면의 다른 포트/도크, 다른 외장 화면, 외장 화면이 주 화면이 아닌 경우다. 핵심 행렬이 재현되지 않을 때만 넓힌다.

### 결정 기준

- 같은 조건의 3회 반복에서 Space 화면 소속이나 복귀 순서가 달라지면 자동 복원 대상에서 제외한다.
- `Desktop N`은 내부 ID가 유지돼도 번호가 바뀔 수 있으므로 저장 키로 쓰지 않는다.
- 전체 Space 이동이 Mission Control UI 또는 Dock 주입에만 의존하면 제품 기본 기능으로 만들지 않는다.
- 공개 API가 생기기 전까지 완전 자동화의 상한은 “읽기 전용 감지 → 사용자 안내 → 좌표 복원”이다.

## 후속 조사: 현재 Desktop 1–4 읽기 전용 관찰

### 이번 판정

현재 맥의 실제 구성은 private SkyLight snapshot에서 **내장 화면의 일반 Desktop 2개 + 외장 화면의 일반 Desktop 2개**로 읽혔다. 현재 Mission Control UI와 배열 순서를 대조하면 내장 화면이 `Desktop 1/2`, 외장 화면이 `Desktop 3/4`다. 이 대응은 현재 상태에 대한 실측이지 Apple의 공개 계약은 아니다.

공개 API만으로는 같은 결론을 낼 수 없다. 공개 API는 화면 2개와 개별 Spaces 설정이 켜졌다는 사실, 전체 Space를 포함하면 창 번호 목록이 더 커진다는 사실까지만 알려준다. `4개 Space`, `Desktop 1–4`, 화면별 2개, 각 Space의 ID는 어느 것도 공개하지 않는다.

private 읽기는 현재 상태를 진단하는 데는 충분했다. 하지만 다음 로그인·재부팅에도 쓸 영구 키는 확인하지 못했다. 숫자 ID는 매번 새 snapshot에서만 써야 하고, private Space 이름값도 같은 로그인 세션의 보조 힌트 이상으로 승격하면 안 된다.

### 측정 범위와 안전선

- 환경: macOS 26.5.2, 화면 2개, `NSScreen.screensHaveSeparateSpaces == true`.
- `NSApplication.shared`가 초기화된 실제 AppKit 컨텍스트에서 공개 API를 측정했다. 설정, Space, 창, Mission Control, 로그인 상태, Dock, 케이블은 바꾸지 않았다.
- SkyLight는 `dlopen`/`dlsym`으로 조회 심볼만 열었다. `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`, `SLSSpaceGetType`, `SLSSpaceCopyName`만 호출했다.
- 실제 화면 UUID, Space 이름/UUID, 숫자 Space ID, 창 번호, 앱·창 제목은 출력하거나 이 문서에 기록하지 않았다. 아래 결과는 개수와 익명 라벨뿐이다.

### 공개 API의 실제 상한

| 관찰 | 현재 결과 | 알 수 없는 것 |
|---|---:|---|
| `NSScreen.screens` | 2개 | 각 화면의 Space 수·순서·ID |
| [`NSScreen.screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces) | `true` | `Desktop 1–4`의 존재와 소속 |
| `NSWindow.windowNumbers(.allApplications)` | 48개 | 비활성 Space별 창 묶음 |
| `NSWindow.windowNumbers([.allApplications, .allSpaces])` | 52개 | 각 창의 Space ID·화면 소속 |

두 창 목록의 차이는 비활성 Space에 창 번호가 더 있다는 뜻일 뿐, Space가 몇 개인지 역산할 수 있는 정보가 아니다. 공개 `CGDirectDisplayID`도 연결된 화면의 런타임 식별자이며 Apple은 보통 재시작 전까지 일정하다고만 설명한다. Space 키는 아니며 장기 프로필 키로 저장하면 안 된다. [Apple `CGDirectDisplayID` 문서](https://developer.apple.com/documentation/coregraphics/cgdirectdisplayid)

### private snapshot에서 본 현재 topology

`SLSCopyManagedDisplaySpaces`의 `Display Identifier`를 공개 ColorSync의 [`CGDisplayCreateUUIDFromDisplayID`](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid%28_%3A%29) 결과와 메모리 안에서만 비교해 물리 화면 종류를 붙였다. 그 뒤 각 화면의 `Spaces` 배열을 순서대로 읽었다.

| 익명 UI 라벨 | 물리 화면 | 화면 안 순서 | private type |
|---|---|---:|---:|
| `D1` (`Desktop 1`) | 내장 | 1 | 0, 일반 user Space |
| `D2` (`Desktop 2`) | 내장 | 2 | 0, 일반 user Space |
| `D3` (`Desktop 3`) | 외장 | 1 | 0, 일반 user Space |
| `D4` (`Desktop 4`) | 외장 | 2 | 0, 일반 user Space |

네 Space에는 모두 `uuid`, `id64`, `ManagedSpaceID` 필드가 있었고 각 필드의 현재 값은 네 레코드 사이에서 구분됐다. `id64 == ManagedSpaceID`도 현재 네 건 모두에서 성립했다. 이것은 현재 OS·현재 snapshot의 관찰일 뿐 두 필드가 항상 같다는 계약이 아니다.

`Desktop N`은 별도 저장 이름으로 보이지 않았다. 현재 [yabai의 Mission Control index 계산](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L491-L549)도 `SLSCopyManagedDisplaySpaces`의 화면 배열과 그 안의 Space 배열을 매번 평탄화해 1부터 번호를 붙인다. 따라서 위 `D1–D4` 대응은 현재 배열의 위치값으로 보는 것이 맞다. Space나 화면 순서가 바뀌면 같은 내부 Space도 다른 `Desktop N`이 될 수 있다.

20회 연속 조회에서는 화면 순서, Space 순서, 세 식별자 값이 모두 같았다. 이는 수백 밀리초 안의 snapshot 일관성만 확인하며, 재연결·로그인·재부팅 안정성의 증거는 아니다.

### 세 private 식별자의 저장 적합성

| 후보 | 현재 관찰과 현행 소스 | 저장 판정 |
|---|---|---|
| `Desktop N` / 전역 index | 현재 배열을 평탄화한 위치 | 저장 금지. 정체성이 아니라 순서 힌트 |
| `id64` | 현재 네 건에서 고유. yabai가 현재 SID로 사용 | 영구 저장 금지. 매 snapshot의 호출 인자로만 사용 |
| `ManagedSpaceID` | 현재 네 건에서 고유하고 `id64`와 같음. Hammerspoon이 raw topology를 정리할 때 사용 | 영구 저장 금지. `id64`와 항상 같다는 계약도 없음 |
| `uuid` / `SLSSpaceCopyName` | 현재 네 건에서 딕셔너리 값과 함수 결과가 같음. 다만 한 Space는 빈 문자열이고 나머지 3개만 UUID 모양 | **nullable 보조 힌트** 후보. 비어 있거나 중복이면 식별 불가 |
| 화면 UUID | 현재 SLS 화면 레코드를 실제 화면과 연결하는 데 성공 | 기존 Plugback 화면 fingerprint를 보조하는 런타임 값. 단독 영구 키로 승격하지 않음 |

익명 라벨별로는 `D1`의 이름이 비어 있었고 `D2`, 외장 화면의 `D3/D4`는 UUID 모양의 비어 있지 않은 이름이었다. 따라서 사용자가 관심 있는 외장 `Desktop 3/4`는 **같은 로그인 세션 hotplug 전후를 비교할 후보**는 있다. 다만 이것을 로그인·재부팅을 넘는 identity라고 부를 근거는 아직 없다.

숫자 SID가 장기 키가 아니라는 가장 강한 현행 소스 증거는 yabai의 hotplug 처리다. yabai는 view를 만들 때 [`SLSSpaceCopyName`을 자체 `uuid`로 보관](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/view.c#L986-L1015)하고, 화면이 추가되면 [새 SID의 이름값으로 기존 view를 찾아 숫자 SID 테이블을 다시 연결](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L1150-L1200)한다. 즉 같은 daemon의 화면 hotplug에서도 숫자 SID가 바뀔 수 있음을 전제로 한 best-effort 구현이다.

반대로 이 소스는 이름값의 재부팅 안정성을 증명하지 않는다. yabai는 시작할 때 [현재 topology를 다시 열거](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L1202-L1232)하며 이전 프로세스의 Space 이름→SID 매핑을 불러오지 않는다. Hammerspoon도 호출할 때마다 private snapshot을 다시 읽는다. 두 프로젝트가 선언한 SkyLight 함수 자체도 Apple 헤더에 없는 private API다. [yabai private 선언](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L18-L61), [Hammerspoon private 선언](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/private.h)

읽기 전용으로 확인한 `~/Library/Preferences/com.apple.spaces.plist`에는 live 화면 레코드 2개×Space 2개, 접속 해제로 접힌 화면 레코드 1개, Space Properties 4개가 있었다. 현재 네 Space의 `uuid`, `id64`, `ManagedSpaceID`는 plist의 네 레코드와 모두 대응했고 Space Properties에도 네 이름과 창 번호 배열이 있었다. 실제 값은 기록하지 않았다. 이 파일은 비공개 구현 자료이며, 디스크에 있다는 사실은 다음 재연결·로그인·재부팅에도 값이 유지된다는 호환성 보장이 아니다.

Plugback 제품 코드가 이 plist를 직접 파싱해서는 안 된다. 이미 live topology와 별도로 접힌 과거 화면 레코드가 남아 있어 현재 화면과 stale 화면을 구분하는 규칙까지 macOS 내부 구현에 종속된다. 실험 기능도 현재 WindowServer snapshot을 원본으로 삼고 plist는 진단 대조 자료로만 취급한다.

현재 확인한 안정성은 다음처럼 한정된다.

| 경계 | 확인 결과 |
|---|---|
| 같은 프로세스의 즉시 반복 조회 | 세 식별자와 순서가 20회 동일 |
| 현재 WindowServer snapshot ↔ 현재 plist | 네 Space 모두 대응 |
| 외장 화면 분리·같은 포트 재연결 | 이번에는 변경 금지 때문에 미측정 |
| 다른 포트·도크를 통한 재연결 | 미측정 |
| 로그아웃·로그인 | 미측정 |
| 재부팅·OS 업데이트 | 미측정 |
| Space 삭제·재생성 | 미측정 |

### 창→Space 매핑은 가능하지만 public AX 창과의 연결이 문제다

현재 `NSWindow.windowNumbers([.allApplications, .allSpaces])`가 준 익명 창 번호 52개를 하나씩 `SLSCopySpacesForWindows(..., 0x7, ...)`에 넣었다.

- 48개는 정확히 한 Space에 속했다.
- 4개는 여러 Space에 속했다. `canJoinAllSpaces` 같은 sticky 창일 수 있다.
- 빈 결과나 현재 네 Space 밖의 결과는 없었다.
- raw membership 수는 `D1=24`, `D2=3`, `D3=24`, `D4=5`였다. 여러 Space 창이 중복되므로 합계는 52보다 크다.

이 수치는 사용자 앱의 표준 창 개수가 아니다. WindowServer 목록에는 overlay, tooltip, off-screen·system window도 섞인다. Hammerspoon도 [`SLSCopyWindowsWithOptionsAndTags` 결과에 false positive가 많다](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces.m#L88-L139)고 경고한다. 현재 yabai와 Hammerspoon이 창 membership을 얻는 방식 역시 [`SLSCopySpacesForWindows`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window.c#L31-L110)를 직접 호출하는 private 구현이다. [Hammerspoon 구현](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces.m#L202-L238)

Plugback의 창 객체는 공개 Accessibility의 `AXUIElement`다. 공개 AX 표준 속성에는 이 객체를 `CGWindowID`로 바꾸는 키가 없으므로 위 mapping과 바로 join할 수 없다. private `_AXUIElementGetWindow`를 하나 더 쓰거나, PID·frame 같은 값으로 `CGWindowList`와 추정 매칭해야 한다. 전자는 private API 위험을 하나 더 만들고 후자는 같은 앱의 비슷한 창에서 모호하다. `CGWindowID` 자체도 창이 닫히거나 앱이 재실행된 뒤 쓸 영구 프로필 키가 아니다.

### Plugback의 최소 모델

첫 vertical slice는 영속 `Profile`에 **Space 필드를 저장하지 않는다.** 현재 실측은 읽기가 가능하다는 증거이지 비활성 Space 자동 복원이 안전하다는 증거가 아니다. 같은 프로세스 안의 메모리 overlay만 쓰는 후속 결정은 [활성 Space 기반 복원 구현 계획](../ACTIVE_SPACE_RESTORE_PLAN.md)에 있다.

특히 runtime topology 감지와 Space·창 mutation은 별도 capability다. 이번 결과는 전자를 보여줄 뿐이며, 후자에는 여전히 공개 API가 없다. 감지가 성공했다는 이유로 private 창 이동이나 Dock/Mission Control 조작을 활성화하지 않는다.

private 읽기 전용 실험을 만든다면, 현재 `앱별 unitRect 하나`를 바로 크게 일반화하지 말고 다음 힌트만 격리해 저장한다.

```text
SpaceHint
  opaqueName: String?     // SLSSpaceCopyName; 비어 있거나 중복이면 nil 취급
  localOrderHint: Int     // 해당 화면 안 순서; identity가 아니라 확인용

WindowPlacement
  bundleID: String
  spaceHint: SpaceHint?
  unitRect: UnitRect
```

화면은 기존 profile의 화면 fingerprint를 그대로 쓴다. `id64`, `ManagedSpaceID`, `Desktop N`, `CGWindowID`는 저장하지 않고 복원 때 새 snapshot에서만 계산한다. `opaqueName`이 유일하게 다시 나타나고 화면 fingerprint와 local order도 모순되지 않을 때에만 “같은 Space일 가능성이 높다”고 판단한다. 이번처럼 이름이 빈 첫 Space는 자동 식별 대상에서 빠진다.

같은 앱의 창을 `D3`, `D4`에 하나씩 두는 경우까지 표현하려면 `TargetApp` 하나가 아니라 `(bundleID, SpaceHint)`별 `WindowPlacement`가 필요하다. 다만 같은 앱의 창이 같은 Space에 둘 이상이면 이 최소 모델도 구별하지 못한다. 그런 앱은 제목을 영구 키로 추가하지 말고 통째로 건너뛴다.

### 반드시 fail closed 할 조건

- private 심볼이 없거나 반환 딕셔너리 형식이 달라지면 Space 기능 전체를 끄고 기존 좌표 복원으로 돌아간다.
- `opaqueName`이 비었거나 중복, 사라짐, 새로 생성됨 중 하나면 자동 대응하지 않는다.
- 화면 fingerprint, Space 이름, local order 중 둘 이상이 충돌하면 순번으로 추측하지 않는다.
- `id64`와 `ManagedSpaceID`가 달라도 한쪽을 영구 진실로 간주하지 않고 해당 snapshot을 거부한다.
- AX↔CGWindow join이 실패하거나 후보가 여러 개면 그 창을 건너뛴다.
- 창 membership이 0개 또는 2개 이상이면 sticky/불명 상태로 보고 이동하지 않는다.
- private type이 일반 user Space `0`이 아니면 전체 화면·Split View·system Space로 보고 제외한다.
- 재연결 직후 topology가 연속 두 snapshot에서 같지 않으면 현재 1.5초 debounce가 끝나도 복원하지 않는다.
- 로그아웃·재부팅·OS 업데이트 뒤에는 아래 실험으로 검증되기 전까지 저장된 private 힌트를 신뢰하지 않는다.
- mismatch를 발견해도 private API나 Mission Control UI로 Space를 자동 이동하지 않는다. 사용자에게 Mission Control 정리를 안내한 뒤 좌표만 복원한다.

### 식별자 안정성 실험의 최소 추가 행렬

각 회차에서 실제 값은 로컬 테스트 로그에서만 해시하고, 문서에는 `같음/변경/소실/중복`만 남긴다. 전후로 `uuid/SLSSpaceCopyName`, `id64`, `ManagedSpaceID`, 화면 UUID, 화면별 local order, 창 membership을 함께 비교한다.

| 번호 | 상태 변화 | 통과 기준 |
|---|---|---|
| A | 같은 포트에서 외장 화면 분리 → 5초 → 재연결, 3회 | Space 이름과 창 membership이 3회 모두 원래 외장 화면으로 대응. 숫자 SID가 바뀌어도 이름으로 새 SID를 유일하게 resolve 가능 |
| B | 같은 화면을 다른 포트 또는 도크로 재연결 | 화면 fingerprint와 Space 이름을 함께 사용해 한 가지 대응만 나옴 |
| C | 외장 화면 연결 상태에서 로그아웃 → 로그인 | 네 Space 이름·화면 소속이 유일하게 대응하고 빈 이름이 늘지 않음 |
| D | 완전 재부팅 뒤 같은 구성으로 연결 | C와 같고 plist의 잔존 레코드가 live topology와 혼동되지 않음 |
| E | Space 하나 삭제 후 새로 생성 | 새 Space가 기존 힌트로 오인되지 않고 해당 placement만 안전하게 무효화됨 |

A가 안정적이어도 같은 로그인 세션의 안내 기능까지만 허용한다. C·D까지 지원하려면 지원할 각 macOS 버전에서 3회 반복이 모두 같아야 한다. 한 번이라도 이름 소실·중복이나 잘못된 화면 대응이 나오면 private Space profile 저장은 중단한다.

## 후속 조사: Space 추가와 fullscreen·Split View 캡처

### 결론부터

1. 현재처럼 내장 화면의 Space 배열이 외장 화면 배열보다 먼저 오는 상태에서 **내장 일반 Space가 하나 추가되면**, 외장 두 Space의 private Mission Control index는 `3/4 → 4/5`로 한 칸씩 밀린다. 단, 이것은 현재 배열을 평탄화한 위치값이며 Apple이 보장한 UI 이름이 아니다.
2. 내장 화면에 single native fullscreen 또는 Split View가 생겨도 private topology에는 type `4` Space 레코드 하나가 추가된다. single fullscreen의 창 1개와 Split View의 창 2개는 각각 **Space 한 칸**을 차지하므로, 둘 다 뒤쪽 index를 한 칸만 민다.
3. 일반 Space의 raw membership과 창 수는 비활성 상태에서도 읽을 수 있지만, 로컬 실측에서 Finder와 Zed의 AX 표준 창은 해당 Space를 활성화하기 전까지 열거되지 않았다. 제품급 캡처와 복원은 활성 Space에서만 허용한다.
4. fullscreen/Split View는 private type과 membership으로 **감지·기록**할 수 있지만, 다른 앱을 같은 native fullscreen/Split View로 **복원**하는 공개 API는 없다. v1은 type `4`를 좌표 복원 대상에서 제외하고 사용자 안내와 사후 검증만 해야 한다.

### index가 실제로 밀리는 방식

[yabai의 현재 계산](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L491-L549)은 화면 배열을 순서대로 돌고, 각 화면의 `Spaces` 배열을 **type 구분 없이** 모두 세면서 1부터 번호를 붙인다.

```text
현재
  내장: [I1(type 0), I2(type 0)]
  외장: [E1(type 0), E2(type 0)]
  index: I1=1, I2=2, E1=3, E2=4

내장에 일반 Space I3 추가 뒤의 배열이 [I1, I2, I3]이면
  내장: [I1(type 0), I2(type 0), I3(type 0)]
  외장: [E1(type 0), E2(type 0)]
  index: I1=1, I2=2, I3=3, E1=4, E2=5

I3 대신 fullscreen 또는 Split View F가 들어와도
  내장: [I1(type 0), I2(type 0), F(type 4)]
  외장: [E1(type 0), E2(type 0)]
  index: I1=1, I2=2, F=3, E1=4, E2=5
```

위 계산은 “새 레코드가 내장 배열의 기존 두 Space 뒤, 외장 배열보다 앞에 들어왔다”는 조건부 결과다. raw display 배열에서 외장이 내장보다 먼저 오면 내장 Space 추가는 외장 index를 밀지 않는다. 자동 재정렬, 사용자의 수동 재정렬, 화면 배열 순서 변화가 있으면 새 snapshot으로 다시 계산해야 한다. index를 저장 키로 쓰면 안 되는 이유다.

UI 표기도 나눠 봐야 한다. 일반 type `0` Space만 있는 현재 구성에서는 private index와 `Desktop 1–4`가 일치했다. 반면 Apple은 full-screen과 Split View 썸네일을 Spaces bar에 표시한다고 설명하지만, 그 썸네일은 보통 앱 이름이나 앱 조합으로 보이며 `Desktop N` 이름이라고 보장하지 않는다. Hammerspoon도 [Mission Control의 표시 이름을 화면별 AX 버튼 순서에서 별도로 읽어 매핑](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L621-L667)한다. 따라서 type `4`가 섞이면 `E1의 private index가 4`와 `UI에 Desktop 4라고 표시된다`를 같은 주장으로 쓰지 않는다. [Apple의 여러 Spaces 안내](https://support.apple.com/en-ie/guide/mac-help/mh14112/mac)

### type `0`과 type `4`의 의미

이 숫자는 Apple 공개 API가 아니라 현재 SkyLight 구현값이다.

- yabai는 [`SLSSpaceGetType == 0`을 user Space, `== 4`를 fullscreen Space](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space.c#L88-L100)로 판정한다.
- Hammerspoon은 [type `0`을 `user`, type `4`를 “fullscreen 또는 tiled window pair”](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L539-L565)로 노출한다. 즉 type `4`만으로 single fullscreen과 Split View를 구별하지 못한다.
- Apple의 공개 설명도 native fullscreen 진입 시 Cocoa가 새 Space를 만든다고 설명한다. [Apple Full-Screen Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/FullScreenApp/FullScreenApp.html)
- 현재 Apple 사용 설명서는 Split View도 새 desktop space에 만든다고 명시한다. 두 창은 그 Space 하나를 공유한다. [Apple Split View 안내](https://support.apple.com/en-ca/guide/mac-help/mchl4fbe2921/mac)

초기 snapshot은 화면 레코드 2개, Space 4개 모두 type `0`이었다. 이후 외장 화면에서 Zed를 native fullscreen으로 만들자 외장 Space 배열에 type `4` 레코드 하나가 추가됐고, 활성화했을 때 Zed의 `AXFullScreen=true`와 단일 type `4` membership을 함께 확인했다. Split View는 아직 로컬 상태 전환을 측정하지 않았다.

### type별 창 membership

Hammerspoon의 `windowsForSpace`는 type `0`과 `4`에 모두 [`SLSCopyWindowsWithOptionsAndTags`](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces.m#L88-L139)를 호출한다. yabai도 같은 private 호출 뒤 WindowServer tag·attribute·level을 여러 단계로 걸러낸다. [yabai 필터](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space.c#L17-L80)

따라서 다음은 현재 구현상 가능하다.

- 일반 Space 하나에 속한 raw 창 ID 집합 읽기
- type `4` Space에 속한 raw 창 ID 집합 읽기
- 각 raw 창의 PID·bounds를 조회해 앱과 기하 정보 후보 만들기
- `SLSCopySpacesForWindows`로 한 창이 어느 Space 또는 여러 Space에 속하는지 역조회

하지만 raw membership에는 overlay, tooltip, auxiliary window, off-screen window가 포함될 수 있다. single fullscreen에도 auxiliary 창이 있을 수 있으므로 “raw 창 1개면 single, 2개면 Split”으로 판정하면 안 된다. AX의 root standard window로 성공적으로 연결된 **주 창**만 센 뒤 정확히 1개면 `fullscreenSingle` 후보, 정확히 2개면 `splitPair` 후보로 삼는다. join 실패·중복·3개 이상이면 `unsupported`다.

### `AXFullScreen`의 공개·비공개 경계

공개 API가 제공하는 정보는 범위가 좁다.

- 자기 앱의 `NSWindow`는 [`styleMask.contains(.fullScreen)`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullscreen)로 native fullscreen 상태를 볼 수 있다.
- [`fullScreenAllowsTiling`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenallowstiling)은 자기 창이 tile에 참여할 수 있다는 **능력**이지, 현재 Split View인지 또는 상대 창이 무엇인지 알려주는 상태가 아니다.
- 공개 Accessibility의 [`kAXFullScreenButtonAttribute`](https://developer.apple.com/documentation/applicationservices/kaxfullscreenbuttonattribute)는 창의 full-screen 버튼 UIElement를 주는 읽기 전용 convenience attribute다. 버튼 존재는 현재 fullscreen 상태나 Split View pairing이 아니다.
- macOS SDK 26.5의 공개 `AXAttributeConstants.h`에는 상태용 `kAXFullScreenAttribute`가 없다.

반면 Plugback은 이미 AX 창에서 raw 문자열 [`"AXFullScreen"`](../../Sources/PlugbackKit/AXWindowGateway.swift#L57)을 읽는다. 현재 yabai도 이 문자열을 [자체 `kAXFullscreenAttribute`로 선언](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window.h#L1-L5)해 [값을 읽고](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window.c#L830-L840), 창 생성 때는 [이 값 또는 Space type `4`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window.c#L1115-L1127)를 함께 사용한다. 이는 널리 작동하는 read-side 관찰값일 수는 있어도 Apple 공개 계약은 아니다.

`AXFullScreen` 하나만으로는 다음을 알 수 없다.

- 해당 창의 private Space ID와 화면 안 순서
- single fullscreen인지 Split View의 한쪽인지
- Split View의 상대 창과 좌우 순서·divider 비율
- 값을 쓰면 모든 앱이 같은 방식으로 native fullscreen을 만들지

창 frame이 화면 전체인지 또는 절반인지로만 판정하는 것도 maximized 창, 일반 window tiling, borderless 창과 혼동한다. AppKit의 `NSSplitView`는 앱 내부에서 여러 view를 나누는 UI 클래스이며 Mission Control의 두 앱 Split View를 조회·복원하는 API가 아니다.

### 세 경우의 최소 캡처 정보와 복원 경계

| 경우 | 최소 캡처 정보 | 읽기 가능 범위 | Plugback 복원 경계 |
|---|---|---|---|
| 일반 Space | `SpaceHint`(화면 fingerprint, nullable name, local-order hint, type `0`) + 각 주 창의 bundle ID·`unitRect` | 비활성 상태에서는 topology와 raw membership만 보인다. AX 표준 창·frame·join은 사용자가 그 Space를 활성화한 뒤에만 확정 | 같은 Space가 이미 존재하고 활성화됐을 때 geometry만 복원. Space 생성·이동은 하지 않음 |
| single native fullscreen | `SpaceHint`, type `4`, 주 창 1개의 bundle ID와 창 후보 fingerprint, 의도한 화면 | SLS type `4` + 주 창 membership으로 감지. raw `AXFullScreen`은 보조 확인 | 다른 앱을 fullscreen으로 전환하지 않음. 사용자가 fullscreen을 만든 뒤 membership만 검증 |
| Split View | `SpaceHint`, type `4`, 주 창 2개의 bundle ID/창 후보 fingerprint, leading/trailing, divider fraction hint | 두 주 창이 같은 type `4`에 유일하게 join될 때만 `splitPair`로 기록 | pairing·tile 순서·divider를 자동 생성하지 않음. 사용자가 Split View를 만든 뒤 구성과 비율을 검증·안내 |

일반 Space의 “각 앱 레이아웃”은 **앱당 그 Space에 표준 창이 하나**라는 좁은 조건에서는 저장할 수 있다. 같은 앱의 창이 같은 Space에 여러 개면 bundle ID만으로 구별할 수 없고, 창 제목을 영구 키로 추가해도 문서·탭 변경 때문에 안정적이지 않다. 그 Space 전체 캡처를 실패 처리하는 편이 안전하다.

single fullscreen은 화면을 채우는 것이 시스템 관리 상태이므로 현재 `unitRect`를 저장해 일반 창처럼 쓰는 모델이 맞지 않는다. Split View의 두 frame에서 divider 비율을 추정해 안내값으로 저장할 수는 있지만, 그 frame을 AX로 다시 쓰면 native Split View가 아니라 일반 창 두 개가 반쪽에 놓일 뿐이다.

private write 경로까지 허용하면 경계가 조금 달라진다. 같은 type `4` Space가 살아 있는 동안에는 whole-Space를 화면 사이로 옮겨 single fullscreen이나 pair를 통째로 보존할 가능성이 있다. yabai가 쓰는 경로는 [Dock scripting addition을 통한 private Space 이동](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L891-L923)이며 보안 설정과 버전 의존성이 있고, type `4` pair 보존은 이번에 실측하지 않은 추론이다. 반대로 Hammerspoon은 [fullscreen/tiled Space에서 개별 창 이동을 기본 거부](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces.m#L142-L199)한다. type `4` Space가 사라진 뒤 같은 Split pair·side·divider를 정확히 다시 만드는 검증된 API는 두 프로젝트에도 없다. 따라서 Plugback production 경계는 여전히 “살아 있는 구성 감지·검증”까지다.

### 현재 Plugback 모델에 미치는 영향

현재 코드에는 창 단위 `isFullscreen`은 있지만 profile의 [`TargetApp`](../../Sources/PlugbackKit/Model.swift#L94)은 bundle ID당 `unitRect` 하나만 저장한다.

- [`AXWindowGateway`](../../Sources/PlugbackKit/AXWindowGateway.swift#L57)는 undocumented `AXFullScreen`을 읽지만 Space type·Space ID·Split partner는 모른다. 더구나 attribute 부재·타임아웃·타입 불일치를 `?? false`로 windowed와 합치므로 현재 판정은 fail-open이다.
- [`CaptureEngine`](../../Sources/PlugbackKit/CaptureEngine.swift#L22)은 fullscreen 창을 저장 대상에서 완전히 제외한다.
- [`RestoreEngine`](../../Sources/PlugbackKit/RestoreEngine.swift#L175)도 fullscreen 창만 남으면 `.fullscreen`으로 건너뛴다.
- 앱별 첫 창 하나만 저장하므로 같은 앱의 `E1/E2` 창 두 개나 Split View pair를 표현하지 못한다.

따라서 현재 모델을 그대로 두고 index 필드나 `isFullscreen` Bool 하나만 profile에 더해서는 해결되지 않는다. 실험 모델이 필요하다면 최소 단위는 다음 정도다.

```text
SpaceCapture
  hint: SpaceHint
  kind: regular | fullscreenSingle | splitPair | unsupported
  members: [WindowPlacement]
  completeness: complete | incomplete

WindowPlacement
  bundleID: String
  unitRect: UnitRect?       // regular에만 복원값
  tileSlot: leading | trailing | none   // Split은 안내·검증값만
```

`id64`, `ManagedSpaceID`, global Mission Control index, CGWindowID는 저장하지 않는다. `fullscreenSingle`과 `splitPair`의 `members`는 캡처 사실과 사용자 안내를 위한 것이며 기존 좌표 RestoreEngine에 넘기지 않는다.

### 최소 fail-closed 설계

- runtime type이 저장 당시 kind와 다르면 해당 Space 전체를 건너뛴다.
- `isFullscreen: Bool`은 `windowed | fullscreen | unknown` tri-state로 바꾼다. raw `AXFullScreen`을 읽지 못한 경우 `false`로 낮추지 않고 `unknown`으로 두며 캡처 덮어쓰기와 이동을 모두 금지한다.
- type `0`만 기존 position/size 복원 경로에 넣는다.
- type `4`에는 AX position/size, raw `AXFullScreen` 쓰기, full-screen 버튼 press를 하지 않는다.
- type `4`의 주 창이 정확히 1개 또는 2개로 유일하게 join되지 않으면 `unsupported`로 기록한다.
- Split 두 창의 한쪽이라도 같은 앱의 다른 창과 구별되지 않으면 pairing을 추측하지 않는다.
- 비활성 Space에서 AX join이 실패하면 raw WindowServer bounds만으로 profile을 확정하지 않고, 사용자가 해당 Space를 연 뒤 다시 캡처하도록 안내한다.
- Space 이름이 비거나 중복이고 local order도 바뀌었으면 index로 대신 매칭하지 않는다.
- reconnect 직후 같은 topology가 연속 두 snapshot에서 확인되기 전에는 type·membership을 확정하지 않는다.
- 전체 화면·Split View 복원의 성공 기준은 “자동 생성”이 아니라 “사용자가 만든 구성이 저장된 membership과 일치함을 읽기 전용으로 검증”하는 것이다.
