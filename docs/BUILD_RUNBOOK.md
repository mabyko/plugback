# Build Runbook

> **문서 관계**
>
> - [ARCHITECTURE.md](./ARCHITECTURE.md) — 무엇을 만드는지. 이 문서는 그걸 어떻게 빌드해 실기기에 올리는지만 다룬다.
> - [../README.md](../README.md) `Build from source` — 외부 기여자용 1회 빌드 절차(Release, /Applications). 이 문서는 개발 중 반복하는 Debug 루프를 다룬다.
>
> 실제 맥에서 빌드하고 돌려보는 절차. 배포·공증(notarization)은 다루지 않는다.

## 0. 전제


| 항목    | 값                                       |
| ----- | --------------------------------------- |
| macOS | 13 이상 (`LSMinimumSystemVersion`)        |
| Xcode | 15 이상. `xcode-select -p`가 Xcode를 가리킬 것        |
| 하드웨어  | 외장 화면 1대. 이 제품의 동작은 외장 화면 없이는 확인할 수 없다  |


## 1. Local.xcconfig 만들기 (클론·워크트리마다 1회)

`App/Config/Local.xcconfig`는 git 비추적이다. 없으면 번들 ID가 희생용
`forked.plugback.local`로 잡히고 서명 팀도 비어 있다.

```
PLUGBACK_BUNDLE_ID = com.example.plugback.<github핸들>
PLUGBACK_BUNDLE_ID[config=Debug] = com.example.plugback.<github핸들>.dev
DEVELOPMENT_TEAM = <Apple Developer 팀 ID>
```

Debug와 Release가 다른 번들 ID를 쓴다. **손쉬운 사용 권한은 번들 ID마다 따로 잡히므로**,
Debug에서 준 권한은 Release 빌드에 적용되지 않는다.

새 워크트리에서는 기존 체크아웃의 파일을 심볼릭 링크해도 된다:

```bash
ln -s /path/to/main/checkout/App/Config/Local.xcconfig App/Config/Local.xcconfig
```

## 2. 단위 테스트

```bash
swift test   # PlugbackKit — 정책 전부, 앱 빌드 없이
```

판정: `Executed N tests, with 0 failures`. 2초 안에 끝난다. 실패하면 3번으로 넘어가지 않는다.

앱 쪽 표현 매핑(문구·점·헤더·단축어 다이얼로그)은 별도 테스트 타깃이 지킨다:

```bash
xcodebuild test -project App/Plugback.xcodeproj -scheme Plugback \
  -destination 'platform=macOS' -derivedDataPath build
```

판정: `** TEST SUCCEEDED **`. 앱을 빌드해 호스트로 띄우므로 3번 빌드까지 겸한다.

## 3. 앱 빌드

```bash
xcodebuild -project App/Plugback.xcodeproj -scheme Plugback \
  -configuration Debug -derivedDataPath build build
```

판정: `** BUILD SUCCEEDED **`. 산출물은 `build/Build/Products/Debug/Plugback.app`.
`build/`는 gitignore 대상이라 레포를 더럽히지 않는다 — README의 빌드 명령과 같은 경로를 쓴다.
Release 빌드는 `-configuration Release`, 경로도 `.../Products/Release/`로 바뀐다.

## 4. 실기기에서 실행

메뉴바 전용 앱이다(`LSUIElement`). Dock에 안 뜨고, 창도 안 뜬다 — 메뉴바 아이콘으로 확인한다.

```bash
pkill -x Plugback                                  # 이전 빌드가 떠 있으면 먼저 죽인다
open build/Build/Products/Debug/Plugback.app
```

판정: 메뉴바에 아이콘이 생긴다. 안 생기면 `pgrep -x Plugback`으로 프로세스부터 확인한다.

## 5. 손쉬운 사용 권한

창을 읽고 옮기려면 손쉬운 사용(Accessibility) 권한이 필요하다. 앱은 `AXIsProcessTrusted()`로
확인하고, 메뉴의 권한 버튼이 시스템 설정으로 딥링크한다.

권한을 줬는데도 창이 안 움직이면 서명이 바뀌어 TCC 기록이 어긋난 것이다. 초기화 후 다시 준다:

```bash
tccutil reset Accessibility com.example.plugback.<github핸들>.dev
```

> 이 명령은 해당 번들 ID의 권한만 지운다. 인자 없이 실행하면 **모든 앱**의 손쉬운 사용 권한이
> 날아가므로 번들 ID를 반드시 붙인다.

## 6. 화면 식별자 확인 (`screen-probe`)

화면 식별자가 실기기에서 유지되는지 보는 프로브다. 앱과 별개로 돈다.

```bash
swift run screen-probe
```

연결된 화면마다 UUID·지문·해상도를 찍는다. 포트 변경, 재부팅, 클램셸 진입/해제 **전후로** 각각
실행해 UUID가 같은지 비교한다 — 이게 달라지면 프로필이 엉뚱한 화면에 붙는다.

## 7. 실기기 확인 시나리오

1. 외장 화면을 연결한 상태에서 대상 앱 창을 원하는 자리에 놓는다
2. 메뉴에서 저장
3. 케이블을 뽑는다 (창이 내장 화면으로 몰린다)
4. 다시 꽂는다
5. 판정: 대상 앱 창만 저장한 자리로 돌아오고, 내장 화면에 있던 다른 창은 그대로다

## 문제 해결


| 증상                                                 | 원인                                                                |
| -------------------------------------------------- | ----------------------------------------------------------------- |
| `fatal: 'main' is already used by worktree at ...` | main이 다른 워크트리에 체크아웃돼 있다. `git push origin <branch>:main`으로 직접 올린다 |
| 번들 ID가 `forked.plugback.local`                     | 1번 Local.xcconfig가 없다                                             |
| 권한을 줬는데 창이 안 움직임                                   | 5번 `tccutil reset`                                                |
| 메뉴바 아이콘 두 개                                        | 이전 인스턴스가 살아 있다. `pkill -x Plugback` 후 재실행                         |


