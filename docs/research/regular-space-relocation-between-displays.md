# 일반 Space의 화면 간 이동 조사

> 확인일: 2026-09-01
> 환경: macOS 26.6.2 (25G83), Apple Silicon, Xcode 26.6, macOS SDK 26.5
> 전제: **Displays have separate Spaces** 켬
> 범위: 일반 Space(type `0`)만. native fullscreen·Split View(type `4`)는 쓰기 대상에서 제외한다.

> **현재 제품 결정:** 이 문서는 실패·제약의 조사 기록이다. 제품은 Space를 쓰지 않고, 잔류 Space의 출발·목적 화면을 안내해 사용자가 한 번 옮기면 대상 표준 창 위치만 복원한다. 일반 Space 자동 복원과 전체 화면 복원 기능·메뉴는 제거했다.

## 결론

| 작업 | 공개 API | SIP를 켠 실험 경로 | 판정 |
|---|---|---|---|
| 기존 일반 Space를 다른 화면으로 이동 | 프로그래밍 API 없음. Mission Control 수동 drag는 실기기 성공 | direct bridged op은 빈 Space 3/3, 앱 창 포함 Space에서 지연 이동·Dock 불일치 | **제품·Release lab 모두 금지. 빈 희생용 개발 진단만 분리** |
| 특정 화면에 일반 Space 생성 | 없음 | Mission Control의 Dock AX `mc.spaces.add` 누르기. raw `SLSSpaceCreate`는 목표 화면 결합 방법이 불명확 | **보이는 UI 자동화로 best-effort 가능** |
| 타사 창을 특정 일반 Space로 이동 | 없음 | private SkyLight bridged operation. macOS 26.6.1의 SIP-on 일반 앱에서 실기기 성공 | **현실적이지만 same-Space relocation의 대체재는 아님** |
| 생성한 일반 Space 삭제 | 없음 | Mission Control의 Dock AX `AXRemoveDesktop`. raw `SLSSpaceDestroy`는 존재하지만 쓰지 않음 | **빈 probe Space 정리에 한해 best-effort 가능** |

전체 Space 이동·직접 생성·직접 삭제를 조용히 수행하는 현재 yabai 경로는 Dock에 코드를 주입한다. yabai 문서도 `space --display`, `--create`, `--destroy`에 **부분 SIP 해제**가 필요하다고 명시한다. 반면 **창 하나를 특정 Space로 옮기는 일은 별도 경로**다. yabai 7.1.25부터 다시 SIP를 켠 채 동작하며, 현재 소스는 SkyLight의 private bridged operation을 먼저 쓴다. KiwiDesk도 macOS 26.6.1에서 이 창 이동을 SIP가 켜진 일반 AppKit 앱으로 왕복하고 재조회해 확인했다. [yabai 명령 문서](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/doc/yabai.asciidoc#L291-L329), [7.1.25 변경 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L12-L15), [KiwiDesk #884 실기기 기록](https://github.com/KiwiCanopy/KiwiDesk/issues/884)

정확히 같은 Space를 되돌리는 것과 동등한 새 Space를 만드는 것은 분리해야 한다.

- **same-Space relocation**: 같은 runtime SID가 내장 화면에서 A로 옮겨지고 window membership도 그대로 남는다.
- **equivalent reconstruction**: A에 새 type `0` Space를 만들고 저장된 창들을 그 SID로 옮긴다. 원래 Space identity와 내부 화면의 topology는 그대로 복구되지 않는다.

첫 번째는 이미 **사용자의 Mission Control drag로 실기기에서 성공**했다. 그러나 Plugback이 Mission Control을 열고 좌표 기반 mouse-down/drag/up을 합성하는 구현은 화면 배치·애니메이션·사용자 입력에 결합하므로 자동 복원 경로에서 제거한다. 수동 drag 성공은 OS가 같은 Space를 옮길 수 있다는 관찰 근거일 뿐, 합성 drag를 유지할 근거가 아니다.

2026-09-01 private bridged operation의 빈 희생용 Space 왕복은 build `25G83`에서 3/3 통과했다. 그러나 앱 창 포함 회차는 복귀 통과 뒤 대상 SID와 창 프레임이 외장 화면으로 지연 이동하고 Mission Control thumbnail이 orphan 상태가 되어 실패했다. 따라서 **자동 whole-Space 복원을 제공하지 않고 fail closed**한다. 창 단위 이동을 same-Space relocation이라고 부르지 않으며, Dock 주입·부분 SIP 해제도 제품 요구사항으로 채택하지 않는다.

### fullscreen 경로 판정

조사 당시에는 single fullscreen 재생성을 일반 Space 이동과 별개인 실험 경로로 유지했다. 이후 제품 범위를 다시 줄여 raw `AXFullScreen` write, fullscreen binding·후보·복원 코드와 설정 메뉴를 모두 제거했다. 현재는 fullscreen type과 창 상태를 읽어 일반 Space나 이동 가능한 표준 창으로 오인하지 않는 데만 쓴다. 자세한 기술적 한계는 [native fullscreen 조사](./native-fullscreen-space-restore-and-ordering.md)에 남아 있다.

OS 내부 구현은 구분해서 읽어야 한다. 25G83 Dock disassembly에서 native fullscreen Space의 display 배치와 Mission Control drag/reorder가 모두 `_CGSMoveManagedSpaceToDisplayIndex`를 호출한다. 즉 whole-Space primitive는 type `0`/`4`에 공통일 가능성이 높다. 하지만 이는 Dock 내부 semantics의 근거일 뿐, 외부 일반 프로세스의 SIP-on 성공 근거도 아니고 Plugback의 현재 fullscreen 경로가 그 primitive를 쓴다는 뜻도 아니다.

## 조사 기준과 고정 소스

- Apple 공개 계약: 현재 Apple 개발자 문서, 사용자 안내, 로컬 macOS 26.5 SDK 헤더.
- yabai: commit [`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd). 이 HEAD 자체가 “macOS 26.6 Apple Silicon의 scripting-addition `add_space` 수정”이다. [CHANGELOG](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L3-L9)
- KiwiDesk: commit [`b8a642f68f68e9e12976e70125e970af43deb817`](https://github.com/KiwiCanopy/KiwiDesk/tree/b8a642f68f68e9e12976e70125e970af43deb817)와 macOS 26.6.1 SIP-on 실기기 probe [#884](https://github.com/KiwiCanopy/KiwiDesk/issues/884), [#889](https://github.com/KiwiCanopy/KiwiDesk/issues/889).
- SpaceMover: commit [`497ca6d1d7e6ed8b82439ac2aa60ae16ce58791c`](https://github.com/twttr/SpaceMover/tree/497ca6d1d7e6ed8b82439ac2aa60ae16ce58791c). 전체 Space 이동 구현의 권한·검증 방식을 확인하는 반례로만 사용한다.
- Space Manager: commit [`df5fa1accfdfc96afb8b1c06d761807f34635abc`](https://github.com/smunn/mac-space-manager/tree/df5fa1accfdfc96afb8b1c06d761807f34635abc)와 미검증 항목을 남긴 [#5](https://github.com/smunn/mac-space-manager/issues/5).
- Hammerspoon: commit [`23e387e2805a9890066366e0ac96c71b27f0cfd5`](https://github.com/Hammerspoon/hammerspoon/tree/23e387e2805a9890066366e0ac96c71b27f0cfd5).
- Spaceballs: commit [`189dd4cbc1e957e18f81978cfe98ff11a79b2f93`](https://github.com/moltenbits/spaceballs/tree/189dd4cbc1e957e18f81978cfe98ff11a79b2f93). Mission Control 합성 drag의 현재 원소스와 macOS 26 실측 기록을 확인한다.
- AeroSpace: commit [`c548c7f879164c7ab1acde7ecd88f4f19eb53d21`](https://github.com/nikitabobko/AeroSpace/tree/c548c7f879164c7ab1acde7ecd88f4f19eb53d21). native Space가 아닌 virtual workspace 사례를 구분하는 근거다.
- osx-multiscreen-remember: commit [`515e3a00ee059f1e8edaa8fa69b2212a2aa59078`](https://github.com/Expert-Digital-Marketing/osx-multiscreen-remember/tree/515e3a00ee059f1e8edaa8fa69b2212a2aa59078). raw SLS call 뒤 persistence save와 Dock restart를 조합한 2026년 실험 사례다.

이 프로젝트들은 Apple API의 계약을 대신하지 않는다. 여기서는 **현재 공개 소스가 어떤 private call을 어떤 guard와 함께 쓰는지** 확인하는 1차 근거로만 사용한다.

## 커뮤니티 추가 조사

### 무엇을 whole-Space 이동으로 셌는가

이 절에서는 기존 type `0` Space의 **같은 SID/UUID와 전체 window membership이 다른 display로 귀속되는 경우**만 whole-Space 이동으로 센다. 창 몇 개를 다른 Space로 보내기, 활성 Space 전환, 새 Space 생성 뒤 재배치, 앱이 자체적으로 만든 virtual workspace는 별도 범주다. 커뮤니티 글은 실행 결과에 관한 당사자 기록으로만 쓰고, 메커니즘과 권한은 Apple 문서나 해당 프로젝트의 고정 commit 소스로 다시 확인했다.

| 분류 | 원 사례와 실제 메커니즘 | 권한·SIP | 이번 판정 |
|---|---|---|---|
| 사람의 Mission Control drag | Ask Different의 질문은 창이 아니라 Desktop 4 **전체**를 외장→내장으로 옮기는 방법을 묻고, 답은 source display를 다른 Space로 전환한 뒤 비활성 thumbnail을 반대쪽 bar로 drag하라고 한다. Sonoma의 Super User 회차도 “가끔 경계를 못 넘는다”는 현상이 활성 Space라서 생겼고, 2025년 질문자가 답을 확인했다. [Ask Different 답변](https://apple.stackexchange.com/a/457498), [활성 Space 제약·질문자 확인](https://apple.stackexchange.com/questions/436815/move-space-to-different-display#comment667019_457498), [Super User 원문](https://superuser.com/questions/1835924/mission-control-dragging-to-move-spaces-between-multiple-monitors/1837463) | SIP ON, 별도 권한 없음 | **genuine whole-Space 수동 경로**. 활성 Space는 먼저 비활성화해야 한다. 자동 복원은 아니다. 커뮤니티 글 자체는 SID를 기록하지 않았고, strict identity 보존 근거는 위의 25G83 실측이다. |
| AX tree + 합성 pointer drag | Spaceballs는 Dock의 `mc.display`/`mc.spaces.list`에서 tile과 bar frame을 읽고 `CGEvent` mouse-down/drag/up을 보낸다. active Space면 sibling으로 먼저 전환하고, 유일한 Space면 sibling을 만든 뒤, hover-expand·좌표 안정화·0.35초 dwell와 CGS 사후 poll까지 한다. 이는 AX action이 아니라 **Mission Control drag 합성**이다. [구현](https://github.com/moltenbits/spaceballs/blob/189dd4cbc1e957e18f81978cfe98ff11a79b2f93/Sources/SpaceballsCore/SpaceManager.swift#L2831-L3270), [설계·4-display 실측 PR](https://github.com/moltenbits/spaceballs/pull/19), [macOS 26의 동일 UUID 유지 기록](https://github.com/moltenbits/spaceballs/issues/49) | Accessibility 필요, SIP 해제 불필요. private CGS read도 사용한다. [요구사항·설명](https://github.com/moltenbits/spaceballs/blob/189dd4cbc1e957e18f81978cfe98ff11a79b2f93/README.md#L180-L222) | **genuine whole-Space 자동화 사례**지만 제거하기로 한 합성 입력과 정확히 같은 계열이다. elaborate timing과 “즉시 drop하면 원위치로 튕김” guard는 안정성 계약이 아니라 UI timing 의존성을 보여준다. |
| Accessibility action만 사용 | BetterTouchTool 개발자는 entire Desktop 이동/재정렬 요청에 BTT로 할 수 없고 공식 Spaces API가 없다고 답했다. Hammerspoon `hs.spaces`도 `gotoSpace`, add/remove, window→Space만 제공하며 Mission Control의 private AX tree를 여는 experimental 모듈이다. [BTT 원문](https://community.folivora.ai/t/how-to-move-entire-desktop-to-next-monitor/26155/2), [Hammerspoon 모듈](https://www.hammerspoon.org/docs/hs.spaces.html), [고정 소스](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L2-L14) | Accessibility 필요, SIP ON | 기존 Space tile에 “다른 display로 이동”을 수행하는 AX action은 확인되지 않았다. AX는 합성 drag의 element 식별·좌표 취득 수단일 뿐이다. |
| yabai Dock injection | Reddit의 AppleScript 질문에 제시된 script는 실제로는 yabai로 임시 Space를 만들고 `space --display`로 옮겼다가 삭제하며, 작성자도 Space 이동에는 Dock을 장악하기 위한 SIP 해제가 필요하다고 적었다. 최신 원소스도 client 명령을 Dock payload의 private `moveSpace`로 전달한다. [Reddit 원문](https://www.reddit.com/r/applescript/comments/ci17nm/virtual_desktop_management_flip_active_desktops/), [client 호출](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L891-L922), [Dock payload](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L460-L513) | **부분 SIP 해제**, Dock injection, Accessibility 필요. [요구 조건](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/doc/yabai.asciidoc#L35-L44) | **genuine whole-Space 자동화**지만 일반 사용자 배포 경로가 아니다. 원문을 AppleScript-only 또는 SIP-on 성공으로 세면 안 된다. |
| raw SkyLight/CGS | SpaceMover는 raw move 뒤 Dock을 종료하며, injected payload는 적용 상태를 확인하지 않고 OK를 응답한다. osx-multiscreen-remember도 raw move→`SLSPersistenceSaveSpaceConfiguration`→`killall Dock`을 쓴다. [SpaceMover source](https://github.com/twttr/SpaceMover/blob/497ca6d1d7e6ed8b82439ac2aa60ae16ce58791c/SpaceMover/ScriptingAddition/SAManager.swift#L106-L135), [Dock restart 문제 제기](https://github.com/twttr/spacemover/issues/5), [osx-multiscreen-remember binding](https://github.com/Expert-Digital-Marketing/osx-multiscreen-remember/blob/515e3a00ee059f1e8edaa8fa69b2212a2aa59078/bin/workflow-windows.py#L50-L132) | 두 프로젝트의 권한 모델은 다르지만 모두 private ABI와 Dock cache에 의존한다. SpaceMover는 부분 SIP 해제/injection을 요구한다. | host의 populated-Space 실패를 뒤집는 독립 성공 근거가 아니다. 특히 후자는 같은 display 안의 새 fullscreen Space 순서 변경 call site만 공개하며 cross-display regular Space 성공을 보이지 않는다. [call site](https://github.com/Expert-Digital-Marketing/osx-multiscreen-remember/blob/515e3a00ee059f1e8edaa8fa69b2212a2aa59078/bin/workflow-windows.py#L1470-L1501) |
| virtual workspace 이동 | AeroSpace는 native Spaces를 쓰지 않고, 비활성 workspace의 창을 화면 밖 모서리에 두는 자체 emulation이라고 명시한다. `move-workspace-to-monitor`도 이 in-process workspace를 다른 monitor의 active tree로 바꾼다. KiwiDesk의 자체 Space도 같은 off-screen parking 방식이고, 별도로 native Desktop의 창 이동·전환 layer를 더한다. [AeroSpace 설계](https://github.com/nikitabobko/AeroSpace/blob/c548c7f879164c7ab1acde7ecd88f4f19eb53d21/docs/guide.adoc#L427-L452), [move command](https://github.com/nikitabobko/AeroSpace/blob/c548c7f879164c7ab1acde7ecd88f4f19eb53d21/Sources/AppBundle/command/impl/MoveWorkspaceToMonitorCommand.swift#L4-L32), [KiwiDesk의 구분](https://github.com/KiwiCanopy/KiwiDesk/blob/b8a642f68f68e9e12976e70125e970af43deb817/site/src/i18n/en.json#L43-L48) | SIP ON, Accessibility 기반 | 이름이 “workspace/Space 이동”이어도 **native managed Space container 이동이 아니다**. Plugback의 기존 SID·thumbnail·Mission Control topology 복원을 만족하지 않는다. |
| 창 이동·Space 전환 | Stack Overflow의 `CGSMoveWorkspaceWindowList` 답변, Hammerspoon `moveWindowToSpace`, Mission Control에서 창 thumbnail을 끄는 Spoon은 모두 window ID만 옮긴다. yabai `space --swap`도 Space container가 아니라 창과 내부 tiling state를 맞바꾼다. `gotoSpace`나 keyboard/swipe는 표시 중인 Space만 바꾼다. [Stack Overflow 원문](https://stackoverflow.com/questions/6250864/change-to-other-space-macosx-programmatically), [Hammerspoon window 구현](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces.m#L154-L181), [Drag.spoon](https://github.com/mogenson/Drag.spoon/blob/82d2fd81e8d0d92b81268980fd104bea016550c9/init.lua#L163-L218), [yabai swap 설명](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L217-L221) | 경로에 따라 AX 또는 private CGS. whole-Space Dock injection과는 별개 | **false positive**. container identity·빈 Space·전체 membership을 복원하지 않는다. |

MacRumors의 2024년 Sonoma 중심 회차도 Mission Control에서 Space를 다른 display로 drag할 수 있다고 설명하는 한편, monitor 연결 변경 뒤 Space 순서와 앱 할당이 임의로 바뀐다는 후속 사례를 남겼다. 전자는 수동 UI의 독립 확인이고 후자는 topology 복원의 불안정성 보고지만, 어느 쪽도 현재 ABI나 SID continuity를 입증하지 않는다. [수동 drag 설명](https://forums.macrumors.com/threads/move-content-from-one-screen-to-another.2435950/post-33412939), [연결 변경 뒤 순서 문제](https://forums.macrumors.com/threads/move-content-from-one-screen-to-another.2435950/post-33413032), [앱 할당 문제](https://forums.macrumors.com/threads/move-content-from-one-screen-to-another.2435950/post-33413506)

### Sequoia와 macOS 26에서 드러난 제약

- Sequoia 15.4/yabai 7.1.14에서는 두 display의 visible 대상을 `--swap`할 때 window가 원래 display에 남는 간헐 실패가 보고됐다. `--swap`은 container 이동이 아니라 창/tiling-state 교환이므로 whole-Space 실패 증거로 세지 않는다. 다만 window reconstruction도 cross-display에서 atomic하지 않을 수 있다는 최근 경고다. [yabai #2611](https://github.com/asmvik/yabai/issues/2611)
- Sequoia 15.2와 Sequoia 15.7.3/Tahoe 26.3 실기기에서는 SIP를 완전히 해제했는데도 yabai scripting-addition 주입이 실패하거나, 7.1.17에서 실패해 7.1.16 rollback으로 복구된 사례가 있다. 이는 Dock injection을 제품으로 배포할 때 OS뿐 아니라 yabai/SA build 조합도 고정해야 함을 보여준다. [yabai #2501](https://github.com/asmvik/yabai/issues/2501), [yabai #2747](https://github.com/asmvik/yabai/issues/2747)
- Tahoe 26.4 build 25E246/yabai 7.1.17에서는 focused Space의 `space --display`가 exit error 없이 no-op이었고 수동 Mission Control도 active tile을 못 옮겼다는 보고가 있다. maintainer는 7.1.18 업데이트를 지시했고 해당 release는 26.4 scripting addition 갱신을 기록하지만, 원 글에는 multi-display 이동이 고쳐졌다는 후속 확인이 없다. [yabai #2766](https://github.com/asmvik/yabai/issues/2766), [maintainer 답](https://github.com/asmvik/yabai/issues/2766#issuecomment-4222885218), [7.1.18 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L46-L50)
- Tahoe beta에서 Dock binary의 `move_space` pattern을 찾지 못하고 create/destroy/move가 함께 깨졌다가 이후 HEAD 성공 보고가 나왔다. maintainer는 macOS Spaces 전체 model이 Dock에 있고, 안정적으로 조작하려면 Dock 안에서 내부 자료구조도 갱신해야 한다고 설명했다. [초기 pattern 실패](https://github.com/asmvik/yabai/issues/2634#issuecomment-2974843164), [maintainer 설명](https://github.com/asmvik/yabai/issues/2634#issuecomment-3051502747), [후속 성공 보고](https://github.com/asmvik/yabai/issues/2634#issuecomment-3364394363)
- macOS 26.5 build 25F71에서는 display reconfiguration 동안 Space가 삭제되고 창이 surviving active Space로 합쳐진 기록이 있다. 당시 Spaceballs move/restore 동작이 없었다는 진단 로그도 함께 제시됐다. 이는 자동 move 성공/실패 사례는 아니지만, display churn 자체가 identity·rollback을 깨뜨릴 수 있음을 보여준다. [Spaceballs #6](https://github.com/moltenbits/spaceballs/issues/6)
- 예전 yabai whole-Space 이동에서도 화면 회전/종횡비 차이 뒤 black wallpaper, 전체 wallpaper reset과 scripting-addition reload가 보고됐고 maintainer는 사실상 수정하기 어렵다고 답했다. 한 사용자의 대안은 결국 모든 window를 개별 이동하는 것이었다. [yabai #781](https://github.com/asmvik/yabai/issues/781), [maintainer 답](https://github.com/asmvik/yabai/issues/781#issuecomment-1992671025), [window-only fallback](https://github.com/asmvik/yabai/issues/811#issuecomment-769691835)

### persistence save와 Dock restart를 추가하면 되는가

osx-multiscreen-remember는 `SLSMoveManagedSpaceToDisplayIndex` 뒤 `SLSPersistenceSaveSpaceConfiguration`을 호출하고 마지막에 Dock을 한 번 재시작해 Mission Control cache를 새로 읽게 한다. 따라서 **빈 희생용 Space의 developer-only 진단**에서 “topology 변경 뒤 persistence save와 Dock 재기동 시 UI가 따라오는가”를 분리 관찰하는 실험 재료는 된다. [sequence 설명](https://github.com/Expert-Digital-Marketing/osx-multiscreen-remember/blob/515e3a00ee059f1e8edaa8fa69b2212a2aa59078/docs/architecture.md#L59-L87)

그러나 현재 25G83 분석과 맞지 않는 부분이 결정적이다. 이 프로젝트는 wrapper를 `int` 반환·`uint64_t index`로 선언하고 `0`을 성공으로 해석하지만, 25G83 wrapper는 `void`이고 index는 `UInt32`다. 즉 그 success check는 이 호스트에서 의미가 없다. Dock restart도 operation ACK나 rollback이 아니며, 잘못 적용된 topology를 persistence save로 영속화할 위험과 1~2초 UI 중단·payload race가 추가된다. 무엇보다 Plugback의 실제 populated-Space 실패에서는 Dock restart가 orphan thumbnail을 다시 보이게 했을 뿐 잘못 지연 적용된 이동을 취소하지 못했다. **제품·Release lab 재승격 근거가 아니며, 앱 창이 있는 Space에는 이 조합도 시험하지 않는다.** [binding과 return check](https://github.com/Expert-Digital-Marketing/osx-multiscreen-remember/blob/515e3a00ee059f1e8edaa8fa69b2212a2aa59078/bin/workflow-windows.py#L50-L132), [Dock restart 구현](https://github.com/Expert-Digital-Marketing/osx-multiscreen-remember/blob/515e3a00ee059f1e8edaa8fa69b2212a2aa59078/bin/workflow-windows.py#L1489-L1501), [SpaceMover의 restart 위험 보고](https://github.com/twttr/spacemover/issues/5)

### 커뮤니티 조사 결론

재현 가능한 **native whole-Space** 경로는 결국 세 계열로 수렴한다.

1. 사용자가 Mission Control thumbnail을 직접 drag한다.
2. 앱이 같은 UI gesture를 AX geometry와 합성 mouse event로 재현한다.
3. 부분 SIP를 끄고 Dock에 주입해 Dock 내부 Space model과 SkyLight를 함께 갱신한다.

raw SLS ordinary-process 호출은 별도의 네 번째 연구 후보지만, 현재 발견된 커뮤니티 구현은 적용 ACK 없이 persistence save/Dock restart로 UI를 맞추며 cross-display populated regular Space의 안전한 성공 사례를 제공하지 않는다. 공개 API, AX action-only, SIP-on·무합성 whole-Space 제품 경로는 발견하지 못했다. 따라서 합성 drag와 Dock injection을 제외한다는 Plugback 조건 아래에서는 **기존 Space를 자동으로 원래 display에 되돌릴 다음 제품 경로가 없다**. 수동 drag 안내와 현재 Space를 건드리지 않는 passive frame 복원을 유지한다.

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

runtime method encoding은 whole-Space initializer가 `@36@0:8Q16@24I32`, window initializer가 `@32@0:8@16Q24`다. 즉 현재 arm64 ABI에서 `sid`는 `UInt64`, display identifier는 object, index는 `UInt32`다. async base의 `performWithWMBridgeDelegate` encoding은 `v16@0:8`이므로 **적용 결과를 반환하지 않는다**.

`SLSMoveManagedSpaceToDisplayIndex` disassembly는 네 인자를 보존한 뒤 `SLSWindowManagementClientOperationsEnabled`를 확인한다. gate가 켜지면 위 operation을 만들고 SkyLight 내부 async performer에 넘기며, 아니면 `_SLSWindowServerClientMoveManagedSpaceToDisplayIndex`로 간다. fallback은 display identifier가 non-null `CFString`인지 확인한 뒤 one-way Mach message를 보내지만 `mach_msg` 결과를 caller에게 돌려주지 않는다. 따라서 raw wrapper 반환은 성공값이 아니며, 현재 `index`의 0/1-based 의미·범위 처리·목적지 삽입 규칙도 계약돼 있지 않다.

일반 AppKit 프로세스가 bridge 자체를 사용할 가능성은 이전 조사보다 높다. SIP가 켜진 이 호스트에서 AppKit을 실제로 load한 read-only probe가 `SLSBridgedCopyManagedDisplaySpacesOperation.performWithWMBridgeDelegate`의 typed result를 받았다. KiwiDesk는 같은 호출 방식을 쓰고, AppKit load 시 등록되는 delegate가 필요하다고 실기기로 확인했다. 해당 wrapper는 local C++ symbol을 찾지 않고 `NSClassFromString`과 instance `performWithWMBridgeDelegate`를 사용한다. [KiwiDesk bridge wrapper](https://github.com/KiwiCanopy/KiwiDesk/blob/b8a642f68f68e9e12976e70125e970af43deb817/Sources/KiwiDeskCore/OS/WMBridge.swift#L40-L141), [AppKit load 조건과 probe](https://github.com/KiwiCanopy/KiwiDesk/issues/884)

그러나 **whole-Space cross-display write 성공은 별개**다. KiwiDesk의 catalogue에서 `MoveManagedSpaceToDisplayIndexOperation`은 “열거됐으나 미검증”이고 현재 production source에도 구현이 없다. 최신 yabai도 window move에서는 bridged object를 쓰지만 Space move에는 여전히 Dock scripting addition을 쓴다. 이제 25G83 실측도 SIP-on 일반 프로세스가 요청을 전달할 수 있음은 보였지만, 앱 창 포함 Space의 안전한 적용·완료·rollback은 오히려 실패로 판정했다. [미검증 operation catalogue](https://github.com/KiwiCanopy/KiwiDesk/issues/884#issuecomment-5327368781), [yabai symbol lookup](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/yabai.c#L143-L150), [window bridged operation](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L665-L704)

역사적인 CGSInternal header에는 `CGSSpaceCreate(cid, null, options)`와 dictionary key `type`, `uuid`가 기록돼 있다. 하지만 2010년대 reverse-engineered header일 뿐이고, 현재 `SLSSpaceCreate`의 `values`에서 `uuid`가 Space UUID인지 display UUID인지도 검증되지 않았다. 이 자료로 목표 화면 생성 call을 추측해서는 안 된다. [CGSInternal `CGSSpace.h`](https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSSpace.h#L49-L61)

## 1. 기존 일반 Space를 다른 화면으로 이동

### 26.6.2 수동 Mission Control 관찰 기록

A→B→A 뒤 A의 Space들이 내장 화면으로 밀린 실제 상태에서 사용자가 Mission Control을 열고, A의 두 번째 일반 Space thumbnail 하나를 내장 화면의 Spaces bar에서 A 외장 화면의 bar로 drag했다.

| 시점 | 내장 화면 | A 외장 화면 |
|---|---|---|
| drag 전 | regular `4` + type `4` 두 개 | regular `1` |
| drag 후 | regular `3` | regular `2` + type `4` 두 개 |

drag 후 연속 두 snapshot이 동일하게 안정화됐다. 옮긴 regular Space는 **기존 opaque name과 runtime SID를 그대로 유지**했고, Buzz/Zed의 type `4` 두 개도 외장 화면으로 함께 돌아왔다. 이후 Finder의 regular Space와 Buzz/Zed fullscreen Space를 방문했을 때 기존 상태와 위치가 유지됐다. 이 과정에서 Plugback의 AX window move와 fullscreen write 호출은 모두 `0`이었다.

따라서 이 OS와 topology에서는 **같은 Space 자체를 화면 사이로 옮기는 사용자 UI가 실제로 작동한다**. 더구나 fullscreen Space도 같은 외장 화면으로 다시 귀속됐다. 다만 한 회의 관찰만으로 “어떤 regular thumbnail을 옮기면 어느 type `4`가 따라오는지”에 대한 일반 규칙이나 exact local order를 추론하면 안 된다. 다음 회차에는 pre/post SID·display·local order·membership을 모두 기록해 3/3으로 재검증해야 한다.

이 성공은 공개 automation API를 만들지 않는다. Hammerspoon이 쓰는 Dock AX tree에는 `mc.display`의 `AXDisplayID`와 화면별 `mc.spaces.list`가 있어 thumbnail을 찾을 단서는 있다. [display/group lookup](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L83-L150), [Space ID ↔ AX child mapping](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L621-L669) 그러나 기존 Space를 다른 화면으로 보내는 AX action은 확인되지 않았고, 합성 구현은 pointer 좌표·Mission Control animation·사용자 입력에 의존한다.

- **사람이 직접 drag**: 현재 실기기에서 성공한 수동 복구 절차다.
- **Plugback이 visible drag를 합성**: 2026-09-01 결정으로 자동 복원 경로에서 제거한다.
- **SkyLight whole-Space move**: 빈 Space write는 3/3이었지만 앱 창 포함 Space에서 지연 commit과 Dock thumbnail orphan이 발생한 private ABI다.

### 판정

사용자 수동 UI 경로는 **실기기 성공**, 무인 자동 복구는 **제품 불가**다. 합성 drag는 후보에서 제외한다. 조용한 whole-Space 이동이 현재 공개 소스에서 반복 검증된 경로는 yabai식 Dock scripting addition뿐이고, 그 경로는 부분 SIP 해제와 OS별 binary pattern 유지보수가 필요하므로 Plugback 제품에는 넣지 않는다.

Hammerspoon의 고정된 `hs.spaces`에는 Space 생성·창 이동·삭제가 있지만, **기존 Space 전체를 다른 화면으로 옮기는 함수는 없다**. Apple 사용자 문서도 전체 Space의 화면 간 이동을 개발자 계약으로 제공하지 않는다.

### 26.6.2 비표시 UI 후보

첫 lab 후보는 raw C wrapper보다 `SLSBridgedMoveManagedSpaceToDisplayIndexOperation`을 만들고 instance `performWithWMBridgeDelegate`를 호출하는 경로였다. `--space-relocation-probe`가 typed call·validator로 빈 Space A → B → A 검증을 구현한다. AppKit이 등록한 delegate를 그대로 사용하며 hidden local performer를 직접 찾지 않는다. 빈 Space는 3/3 통과했지만 populated Space 실패로 Debug 설정 패널은 제거했다.

가장 작은 검증은 **비어 있고 inactive인 희생용 Space**를 다른 화면 끝으로 한 번 보낸 뒤 stable topology를 비교하는 것이다. 호출 전 조건은 다음과 같다.

- exact OS build allowlist와 class·initializer·performer encoding이 모두 일치한다.
- AppKit이 실제로 load됐고 read operation으로 bridge delegate capability를 확인한다.
- source·destination이 다르고, Mission Control·화면 animation·display reconfiguration이 없다.
- source에 다른 regular Space가 남고, 대상은 inactive tail regular Space이며 SID·opaque name이 stable snapshot 전체에서 유일하다.
- 대상 SID에 layer `0` WindowServer 창 membership이 없고 raw window metadata가 모두 대응된다.
- destination identifier는 같은 live managed-display snapshot에서 가져온다.

성공 조건은 단순히 destination의 Space 수가 늘어나는 것이 아니다.

- 같은 runtime SID와 opaque name이 destination display에 나타난다.
- source에서는 그 SID만 사라지고 다른 Space 순서는 유지된다.
- 해당 SID의 관찰 대상 layer `0` window membership은 그대로다.
- 요청한 `index`와 실제 local order의 관계가 일관된다.
- Dock crash/relaunch, desktop picture 이상, current-Space 변경이 없다.

operation이 async void이므로 dispatch 자체로 성공을 알 수 없다. `index`가 0-based인지, 범위를 벗어난 값을 clamp하는지도 공개 계약이 없다. 첫 probe는 사용자가 직접 만든 빈 희생용 Space에 한해 destination의 마지막 위치 가설 하나만 시도한다. 다른 index나 raw wrapper로 자동 retry하지 않는다. 연속 두 snapshot이 같아진 뒤 위 조건을 모두 만족해야 pass이며, 첫 역이동이 실패하면 자동 cleanup을 멈춘다.

### operation 수명·대기·완료 신호 재판정

앱 창 포함 실패 뒤 가능한 보강안을 다시 대조했지만, 제품 안전성을 만들 근거는 없었다.

| 보강안 | 1차 근거 | 판정 |
|---|---|---|
| caller가 operation을 오래 보관 | 25G83의 Apple C wrapper는 async performer 호출 직후 operation을 release한다. yabai의 실제 SIP-on window bridged 경로도 같은 순서로 즉시 release하며, KiwiDesk wrapper도 local operation을 async performer에 넘긴 뒤 반환한다. [yabai object lifetime](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L665-L704), [KiwiDesk async wrapper](https://github.com/KiwiCanopy/KiwiDesk/blob/b8a642f68f68e9e12976e70125e970af43deb817/Sources/KiwiDeskCore/OS/WMBridge.swift#L125-L141) | caller retain은 문서화된 완료 계약이 아니다. 별도 lifetime 실험은 가능하지만 Dock 불일치와 atomic rollback을 해결하지 못하므로 재승격 근거가 되지 않는다. |
| timeout과 stable read를 늘림 | KiwiDesk는 private op에서 “performed”와 “applied”를 구분하며, 관련 current-Space op은 topology pointer가 약 120 ms 안에 바뀐 뒤에도 창 합성이 끝나지 않아 재조회만으로 시각 완료를 알 수 없었다고 기록한다. [검증 규칙과 실측](https://github.com/KiwiCanopy/KiwiDesk/blob/b8a642f68f68e9e12976e70125e970af43deb817/.claude/rules/os-private-apis.md#L44-L117) | 이번 회차는 두 stable read와 rollback pass **뒤** 원 요청이 지연 적용됐다. 더 긴 유한 timeout은 한 회차의 관찰 확률만 바꾸고, 안전한 완료 경계나 rollback을 만들지 않는다. |
| 공개 Space 알림 | Apple의 `activeSpaceDidChangeNotification`에는 SID·display·operation token이 든 `userInfo`가 없다. 수동 cross-display drag 실측에서도 발행되지 않았다. [Apple API](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification) | 이 operation의 ACK로 쓸 수 없다. |
| Dock AX/Mission Control 완료 신호 | Hammerspoon은 Mission Control을 실제로 열고 private `mc.*` AX tree가 생기길 설정된 시간만큼 기다린다. 이 모듈 자체도 private API와 AX hack을 쓰는 experimental 기능이다. [wait-time 구현](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L204-L212), [module caveat](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L2-L14) | `AXSelectedChildrenChanged`나 `AXUIElementDestroyed`는 보이는 Mission Control tree의 수명 신호이지 hidden bridge request의 ACK가 아니다. 확인하려고 Mission Control을 여는 순간 제거하려는 UI 의존성도 되살아난다. |
| Dock PID 유지·재시작 | 실패 때 Dock PID는 유지됐지만 thumbnail은 누락됐고, Dock 재시작 뒤에야 나타났다. SpaceMover도 raw move 뒤 시각 변경을 적용하려고 Dock을 강제 종료한다. [SpaceMover direct call과 Dock 종료](https://github.com/twttr/SpaceMover/blob/497ca6d1d7e6ed8b82439ac2aa60ae16ce58791c/SpaceMover/ScriptingAddition/SAManager.swift#L106-L135) | PID 유지는 일관성 신호가 아니며, Dock restart는 완료 판정도 rollback도 아닌 사용자 세션 교란 복구다. 제품에서 쓰지 않는다. |

**추론:** SkyLight topology에는 SID가 생겼지만 Dock의 Mission Control model에는 thumbnail이 없었던 패턴과 Dock 재시작 뒤 재등장을 합치면, WindowServer 쪽 이동과 Dock의 private Space model 갱신이 분리된 것으로 보인다. yabai가 Dock 안에서 internal `moveSpace`뿐 아니라 `DPDesktopPictureManager`, current-Space ivar와 show/hide 상태까지 함께 보정하는 구현도 이 해석과 맞는다. 다만 Apple이 원인을 문서화한 것은 아니므로 확정 원인으로 취급하지 않는다. [yabai Dock payload](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L460-L513)

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

SpaceMover도 raw wrapper의 일반 프로세스 성공 근거가 아니다. README는 Dock Mach injection과 `csrutil enable --without debug`를 요구하고, injected payload는 void wrapper를 부른 직후 topology를 재조회하지 않은 채 `SM_STATUS_OK`를 돌려준다. 현재 menu-app 쪽 direct call도 적용 검증 대신 Dock을 강제 종료한다. [SpaceMover 권한 요구](https://github.com/twttr/SpaceMover/blob/497ca6d1d7e6ed8b82439ac2aa60ae16ce58791c/README.md#L25-L34), [payload의 무조건 성공 응답](https://github.com/twttr/SpaceMover/blob/497ca6d1d7e6ed8b82439ac2aa60ae16ce58791c/Payload/payload.m#L43-L75), [direct call과 Dock 종료](https://github.com/twttr/SpaceMover/blob/497ca6d1d7e6ed8b82439ac2aa60ae16ce58791c/SpaceMover/ScriptingAddition/SAManager.swift#L106-L135) 이 사례는 ABI 모양을 교차 확인하지만 SIP-on ordinary-process reliability나 적용 성공을 증명하지 않는다.

### 대안별 제품 tradeoff

| 경로 | Space identity·전체 membership | SIP·배포 | rollback·사용자 영향 | Plugback 판정 |
|---|---|---|---|---|
| Apple 문서의 수동 Mission Control drag | 같은 SID 보존 실측 | SIP ON, 공개 사용자 UI | 사용자가 보고 직접 복구 | 자동화하지 않고 안내 수단으로만 유지 |
| direct bridged op / raw C wrapper | 빈 Space에서는 보존, populated 안전성 실패. raw wrapper도 같은 bridge 또는 one-way fallback | direct op의 SIP-on dispatch만 실측. raw wrapper direct는 미실측이며 둘 다 private API라 App Store 불가 | applied ACK와 atomic rollback 없음. raw wrapper 이점 없음 | populated·Release lab·제품 모두 금지 |
| yabai식 Dock injection | Dock model까지 함께 갱신하며 같은 Space를 옮기는 공개 원소스 구현 | 부분 SIP 해제, Dock injection, 빌드별 pattern과 직접 배포 필요 [요구 조건](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/doc/yabai.asciidoc#L35-L44) | 강한 guard는 있지만 Apple 계약·트랜잭션 rollback 없음 | 기술 reference일 뿐 제품 불가 |
| Dock AX + 합성 Mission Control drag | 사람의 drag와 같은 identity를 노릴 수 있음 | SIP ON, Accessibility 필요 | 보이는 UI·좌표·animation·사용자 입력 충돌 | 사용자 요구에 따라 제거 |
| window→Space + 새/기존 Space 재구성 | 나열한 창만 이동. 새 SID, 빈 Space·전체 membership·order·type `4` follower 손실 | window bridged op은 SIP ON에서 실측됨. 그래도 private API | 일부 창만 움직인 상태의 rollback, 미추적 창 누락 위험 | old same-Space 요구 대체 불가 |
| Space를 건드리지 않고 방문 시 frame만 복원 | 현재 Space identity와 membership을 macOS에 맡김 | 공개 AX 범위, SIP ON | Space가 다른 화면이면 쓰지 않고 기다리므로 destructive rollback 불필요 | **축소된 F-08.5의 채택 경로** |

공개 API만으로 자동 whole-Space 이동을 하는 다른 경로는 현재 SDK에 없다. 새 Space를 만들고 모든 창을 재구성하면 새 identity가 생기며, keyboard shortcut은 활성 Space를 바꿀 뿐 cross-display container 이동을 제공하지 않는다. 따라서 “같은 일반 Space를 조용히 원래 화면으로 자동 이동”을 그대로 유지하는 제3의 제품 경로는 현재 없다.

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

**SIP를 켠 일반 프로세스에서 가장 현실적인 private write**다. 전체 Space를 건드리지 않고 지정한 WindowServer window ID의 membership만 바꾼다. yabai 7.1.25는 이 기능이 다시 SIP를 켠 채 동작한다고 기록한다. KiwiDesk는 macOS 26.6.1에서 다른 앱 Ghostty 창을 Desktop 1→3→1로 옮기고 매번 membership을 재조회했으며, 현재 production wrapper와 verbs도 이 경로를 쓴다. [7.1.25 변경 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L12-L15), [KiwiDesk device probe](https://github.com/KiwiCanopy/KiwiDesk/issues/884), [production wrapper](https://github.com/KiwiCanopy/KiwiDesk/blob/b8a642f68f68e9e12976e70125e970af43deb817/Sources/KiwiDeskCore/OS/WMBridge%2BWindows.swift#L3-L23)

### macOS 26의 우선 call shape

일반 AppKit 앱은 `SLSBridgedMoveWindowsToManagedSpaceOperation`을 runtime lookup하고 `performWithWMBridgeDelegate`를 호출할 수 있다.

```objc
Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
id op = [[cls alloc] initWithWindows:windowIDNumbers spaceID:destinationSID];
[op performWithWMBridgeDelegate];
```

AppKit이 실제로 load돼 delegate를 등록해야 하며, async method는 void다. KiwiDesk의 별도 untrusted `.app` probe에서는 `AXIsProcessTrusted() == false`여도 bridge read와 create/destroy write가 성공했다. 따라서 bridge 자체의 gate는 AX 권한이 아니라 AppKit load로 관찰됐다. Plugback은 타사 창 열거·식별과 frame 복원 때문에 별도로 AX 권한이 필요하다. [AppKit 조건](https://github.com/KiwiCanopy/KiwiDesk/issues/884), [AX-untrusted probe](https://github.com/KiwiCanopy/KiwiDesk/issues/889#issuecomment-5328727628)

yabai는 AppKit delegate 대신 SkyLight Mach-O symbol table에서 local C++ async performer를 찾아 같은 object를 넘긴다. 이는 `dlsym` 가능한 공개 ABI가 아니다. 일반 AppKit 앱인 Plugback이 그 local symbol까지 복제할 이유는 없다. [symbol lookup](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/yabai.c#L143-L150), [operation call](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L665-L704)

어느 호출 방식이든 dispatch와 적용은 다르다. KiwiDesk의 sibling operation은 success-shaped dispatch 뒤 실제 상태가 바뀌지 않는 silent no-op을 보였다. 창 이동도 caller가 destination SID 하나로 membership이 안정화됐는지 재조회해야 한다. [performed ≠ applied 기록](https://github.com/KiwiCanopy/KiwiDesk/issues/889#issuecomment-5328896310)

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

### 제품 요구사항을 대체하는가

아니다. `SLSMoveWindowsToManagedSpace` 계열은 **나열한 window ID만 기존 목적지 SID로 이동**한다. 일반 Space container 자체는 source 화면에 남는다. 따라서 제거된 whole-Space 목표와 비교하면 다음이 빠진다.

- 빈 일반 Space는 옮길 window ID가 없어 복원할 수 없다.
- 같은 runtime SID·opaque name·local order·wallpaper 같은 Space identity를 목표 화면에 보존하지 않는다.
- AX 대상이 아니거나 target app이 아닌 창, auxiliary/sticky/multi-membership 창을 포함한 **전체 membership**을 보존하지 않는다.
- regular Space와 함께 움직인다고 한 번 관찰된 type `4` follower 관계를 복원하지 않는다.
- 새 Space를 만들어 창을 옮기면 새 SID가 생기고 원래 source Space가 남는다.

Space Manager의 현재 “Transfer”도 이 차이를 그대로 보여준다. source Space를 옮기는 대신 열거한 창의 화면 좌표를 바꾸고 wallpaper와 저장 이름을 target display의 **현재 Space**에 복사한다. [transfer 호출부](https://github.com/smunn/mac-space-manager/blob/df5fa1accfdfc96afb8b1c06d761807f34635abc/SpaceManager/App/AppDelegate.swift#L197-L223), [창·wallpaper 구현](https://github.com/smunn/mac-space-manager/blob/df5fa1accfdfc96afb8b1c06d761807f34635abc/SpaceManager/Core/SpaceTransfer.swift#L117-L183) 이 방식은 equivalent reconstruction도 아니라 “선택한 창 배치 복원”이다.

따라서 현재 F-08.5를 유지하면 window move를 whole-Space 실패의 silent fallback으로 쓰지 않는다. 제품 계약을 “Plugback 대상 앱의 창을 목적지 일반 Space에 재배치”로 명시적으로 축소하고 빈 Space·Space identity·전체 membership 복원을 버릴 때만 별도 기능으로 채택할 수 있다.

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
| bridged whole-Space move | bridge 자체에는 불필요 | 불필요 | SIP-on dispatch·빈 Space 이동은 성공, populated 안전성은 실패 | AppKit delegate, private class/selector/ABI, delayed apply, Dock model 불일치 |
| exported SLS Space move wrapper | bridge 자체에는 불필요 | 불필요 | ordinary-process direct 실측 없음 | 같은 bridge 또는 one-way fallback, private ABI, applied ACK 없음 |
| private window→Space bridged op | bridge 자체에는 불필요. Plugback의 타사 AX 창 식별에는 필요 | 불필요 | 켜도 됨 | AppKit load, private class/selector, 비동기 적용 검증 |
| compat-ID window→Space | 창 식별에는 필요 | 불필요 | 켜도 됨 | private SLS symbol과 magic workspace ID |
| whole-Space move/create/destroy SA | yabai 운용에 필요 | 이 작업 자체에는 불필요 | **부분 해제 필요** | Dock injection, OS별 instruction pattern, private ObjC layout/ABI |

Apple은 [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)로 현재 프로세스의 Accessibility 신뢰를 확인하라고 제공한다. prompt는 비동기이며 즉시 반환값을 바꾸지 않는다. 실행 전 `true`가 아니면 probe를 중단한다.

yabai도 Accessibility 승인 뒤 앱을 재시작해야 한다고 적고, Screen Recording은 window animation을 켤 때만 필요하다고 구분한다. 전체 Space command는 별도로 부분 SIP 해제를 요구한다. [requirements](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/README.md#L42-L66) Apple은 SIP가 시스템 앱과 보호 경로를 제3자 변경으로부터 지키는 보안 기능이라고 설명한다. [Apple: About System Integrity Protection](https://support.apple.com/en-us/102149)

안정성 평가는 낮다. 같은 yabai changelog에는 window→Space가 2024년 Sequoia에서 SIP 해제를 요구했다가 2026년 7.1.25에 다시 SIP-on이 된 이력과, 26.6에서 add-space pattern을 다시 고친 기록이 함께 있다. 이는 “현재 동작”과 “다음 macOS update에서도 동작”을 분리해야 한다는 직접 증거다. [2024년 Sequoia 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L134-L140), [2026년 및 26.6 기록](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md#L7-L15)

App Store Review Guideline 2.5.1은 App Store 앱이 공개 API만 사용하도록 요구한다. 따라서 private write가 실제로 동작하더라도 Mac App Store 지원 기능으로 볼 수 없다. Plugback에서 실험한다면 non-sandboxed Developer ID Debug/direct build, OS-build allowlist, fail-closed가 전제다. [Apple App Review Guidelines 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements)

### 26.6.2 최초 read-only presence check

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

exported C wrapper 네 개는 `dlsym`으로 찾을 수 있었지만, `SLSWindowManagementClientOperationsEnabled`와 local C++ bridged performer는 찾을 수 없었다. 이 최초 단계에서는 **symbol/class presence gate만 통과**했다. 이후 direct instance write의 빈 Space 3/3과 populated 실패는 아래 qualification에 별도로 기록한다. raw C wrapper 자체는 ordinary process에서 호출하지 않았다.

추가로 AppKit을 실제 load한 ordinary Swift probe에서 `SLSBridgedCopyManagedDisplaySpacesOperation`의 `performWithWMBridgeDelegate`가 non-nil typed result를 반환했다. 따라서 mutation 전에는 direct instance bridge의 read capability까지 확인했다. 이 read 결과는 뒤의 whole-Space write 성공이나 안전성을 대신하지 않는다.

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

## 최소 DEBUG-only qualification

2026-09-01 서명된 Debug 앱에서 symbol·ABI·read bridge를 확인한 뒤 빈·비활성 tail Space를
direct bridged operation으로 왕복했다. build `25G83`에서 3/3 모두 같은 SID·opaque name의 이동과
baseline 복귀, Dock PID 유지를 확인했다. 이는 앱 창 포함 Space나 Release 자동 복원을 정당화하지 않는다.

### 단계 A1 — 빈 same-Space bridged probe, SIP ON (완료)

첫 3/3은 Plugback Debug 설정의 `Debug · SkyLight` one-shot 패널로 수행했다. 현재는 같은 빈 Space
즉시 왕복 구현을 헤드리스 CLI에 남겼다. stable snapshot과 validator로 안전 후보만 받고 사용자의
희생 확인 뒤 한 번만 왕복한다.
여기서 빈 Space는 layer `0` WindowServer 창 membership이 없는 상태다. Dock·Finder desktop·
WindowServer·알림 센터의 비표준 layer 창은 제외하되, raw window metadata가 하나라도 빠지면
write 전에 거절한다.
헤드리스 진단은 read-only `--space-probe`에서 희생용 `sidToken`과 목적 `displayToken`을 얻어
아래 CLI로 같은 구현을 호출한다.

```text
Plugback --space-relocation-probe <sidToken> <displayToken> --confirm-empty-sacrificial-space
```

1. 두 화면 모두 type `0` Space가 있고 `NSScreen.screensHaveSeparateSpaces == true`인지 확인한다.
2. 사용자가 source 화면에 **빈 일반 Space 하나를 새로 만든다**. inactive tail이며 source에는 다른 regular Space가 남고 opaque name이 유일해야 한다. 기존 사용자 Space를 첫 mutation 대상으로 쓰지 않는다.
3. stable snapshot 두 회로 모든 SID·name·display·order·type·current와 layer `0` membership을 baseline으로 기록한다.
4. exact OS build와 `SLSBridgedMoveManagedSpaceToDisplayIndexOperation`의 class·initializer encoding, async performer encoding을 확인한다. AppKit-loaded read probe가 실패하면 중단한다.
5. 같은 snapshot의 destination identifier와 “목적지 끝” index 가설 하나로 direct bridged operation을 **한 번** dispatch한다. 다른 index·raw wrapper·visible drag로 자동 재시도하지 않는다.
6. 최대 8초 뒤 stable snapshot 두 회로 같은 SID·name의 이동과 전체 불변조건을 확인한다.
7. 저장한 source identifier/index로 같은 SID를 한 번 역이동한다. baseline 복귀가 확인된 뒤에만 3회까지 반복한다.

**pass — association**: 3/3에서 같은 SID·opaque name이 왕복하고 관찰 대상 layer `0` membership, 다른 Space의 display·상대 순서·current 상태가 유지되며 Dock relaunch·desktop picture 이상이 없다.

**pass — order**: association pass에 더해 destination 끝과 source 원래 local order가 매번 같다.

실측 결과: direct bridged operation `3/3`, exact baseline 복귀 `3/3`, Dock 유지 `3/3`.

**fail**: no-op/timeout, SID 교체, 잘못된 display/index, 관련 없는 topology 변화, type `4`의 예기치 않은 이동, Dock relaunch, 역이동 뒤 baseline 불일치 중 하나라도 발생한다. association만 통과하고 order가 실패하면 exact order 복원은 계속 제외한다.

raw C wrapper 비교 실험은 진행하지 않는다. gate가 켜지면 같은 bridged operation으로 가고 꺼지면 applied ACK 없는 one-way fallback으로 가므로, populated 실패를 상쇄할 더 안전한 semantics가 관찰되지 않았다.

### 단계 A2 — 앱 창 포함 시각 확인, SIP ON (실패 · 종료)

내장 화면의 macOS `데스크탑 2`/Buzz를 희생용으로 사용했다. 중간 topology 항목은 Obsidian
fullscreen이었다. move 뒤 Mission Control에서 이동을 확인할 수 없었고 내장 Space는 검정 화면이
됐다. 첫 rollback은 거절됐으며, 잠시 뒤 두 번째 rollback은 stable topology baseline과 Dock PID
유지로 통과했다.

그러나 통과 뒤 대상 SID와 Buzz 창 프레임이 외장 화면 끝으로 지연 이동했다. SID는 비활성인데도
Buzz가 다른 외장 Space에서 계속 보였고, SkyLight에는 외장 type `0` Space가 4개인 반면 Mission
Control에는 3개만 보여 thumbnail이 orphan 상태였다. Debug 앱을 종료하고 Dock을 재시작하자 네 번째
thumbnail이 나타났고, 사용자가 Mission Control로 내장 화면에 옮긴 뒤 membership·창 화면·regular
수(내장 2, 외장 3)가 복구됐다. 정확한 Buzz 좌표는 사용자가 조정했으므로 baseline 근거로 쓰지 않는다.

두 stable read는 async populated operation의 완료·지속성 증명이 아니며 자동 rollback도 안전하지
않다. operation 장기 보관, timeout 연장, 공개 Space 알림, Dock AX lifecycle 중 어느 것도 applied ACK를
제공하지 않는다. 외장 `데스크탑 5`/Mail 회차는 실행하지 않았고 populated 허용 코드와 Debug 설정
패널을 제거했다.

### 단계 B — window→Space, SIP ON

1. test window 하나의 source SID와 frame을 기록한다. source와 destination은 단일 type `0` membership이어야 한다.
2. `SLSBridgedMoveWindowsToManagedSpaceOperation`을 direct AppKit bridge로 한 번 dispatch한다.
3. destination SID 하나만 membership이 될 때까지 재조회하고, 같은 경로로 source에 되돌린 뒤 frame도 복원한다.
4. 3회 반복하되 topology와 다른 membership은 불변이어야 한다.

이 단계가 pass해도 whole-Space qualification을 대신하지 않는다. 창 단위 복원의 별도 capability만 증명한다.

### Mission Control과 equivalent reconstruction 제외

visible Mission Control drag는 더 이상 probe나 제품 fallback이 아니다. Dock AX add/remove를 조합한 equivalent reconstruction도 UI를 다시 열고 새 SID를 만들며 same-Space 왕복 조건을 만족하지 않으므로 이번 대체 경로에서 제외한다. 필요하면 현재 F-08.5와 분리된 “Space 자체 복원” 요구사항으로 다시 설계한다.

### yabai는 선택적 reference oracle일 뿐이다

이미 부분 SIP가 해제된 전용 lab이라면 pinned yabai `dd84572`로 sacrificial Space의 `--display` 왕복을 비교할 수 있다. Plugback을 위해 SIP를 해제하거나, yabai scripting addition을 제품 dependency로 추가하지 않는다. oracle이 성공해도 “Dock 주입으로 가능”만 확인하며 raw wrapper의 성공 근거가 되지 않는다.

### rollback 우선순위

실패해도 다음 순서만 실행한다.

1. test window는 기록한 original SID로 한 번 되돌리고 frame을 복원한다.
2. 빈 whole-Space CLI probe는 희생용 SID에만 저장한 source display/index 역호출을 한 번 수행한다.
3. populated Space에는 자동 rollback을 수행하지 않는다. current snapshot을 출력하고 native Mission Control 수동 복구만 사용한다. raw destroy는 호출하지 않는다.

## Plugback 판단

1. **Mission Control + 합성 mouse drag는 일반 Space 자동 복원에서 제거**한다.
2. qualification 전에는 raw wrapper + exact-build allowlist + 사후 stable snapshot만으로도 부족하다. 사후 검증은 오이동을 발견할 뿐 역복구 실패를 예방하지 못하므로, 기존 사용자 Space를 다루는 Release 실험실 경로도 비활성화한다.
3. 빈 희생용 Space의 bridged 왕복은 exact build에서 3/3 통과했지만 populated 회차가 실패했다. 이 primitive는 사용자 Space를 만지는 기본 OFF Release lab나 제품 경로로 승격하지 않는다. 남기더라도 개발자가 직접 만든 빈 희생용 Space만 받는 명시적 destructive CLI 진단으로 격리한다.
4. `SLSMoveWindowsToManagedSpace` 계열은 SIP-on에서 현실적이지만 예전 same-Space 요구의 identity·빈 Space·전체 membership을 만족하지 않는다. silent fallback으로 쓰지 않는다. 현재 축소된 F-08.5처럼 Space가 목표 화면에서 active가 될 때까지 기다렸다가 저장 창의 frame만 복원하는 경로에는 membership write 자체가 필요 없다.
5. single fullscreen 복원은 Mission Control drag를 쓰지 않으므로 유지한다. 정확한 fullscreen 순서와 Split View는 계속 제외한다.
6. raw create/destroy, Dock injection, Dock 강제 재시작, 부분 SIP 해제는 Plugback 배포 요구사항으로 채택하지 않는다.
