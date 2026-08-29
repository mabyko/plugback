# 활성 Space 기반 복원 구현 계획

## Plugback

> **문서 관계**
> - [FUNCTIONAL_SPEC.md](./FUNCTIONAL_SPEC.md) — 현재 제품 동작의 기준. 이 계획이 구현·검증되기 전까지 본 계획보다 우선한다.
> - [ARCHITECTURE.md](./ARCHITECTURE.md) — 현재 모듈과 interface. 새 seam은 실기기 게이트 통과 뒤에만 반영한다.
> - [RESTORE_FLOW.md](./RESTORE_FLOW.md) — 현재 복원 순서. 활성 Space 흐름이 제품에 들어갈 때 함께 갱신한다.
> - [UNDOCUMENTED_APIS.md](./UNDOCUMENTED_APIS.md) — 비공식 이름의 목록과 fail-closed 정책.
> - [research/mission-control-spaces-on-external-screens.md](./research/mission-control-spaces-on-external-screens.md) — 공개 문서, 외부 사례, 로컬 실측 근거.

- 상태: **승인된 구현 계획 · 제품 동작은 아직 미구현**
- 작업 브랜치: `feature/active-space-restore`
- 작성일: 2026-08-27
- 적용 방식: 실험실 · 기본 꺼짐

---

## 1. 결정

비활성 Space의 창을 한 번에 열거해 전부 복원하는 원안은 폐기한다. 현재 macOS와 Plugback 앱 신원에서는 비활성 Space의 raw 창 membership은 보이지만, 이동 가능한 AX 표준 창이 열거되지 않는다.

대신 다음 한 가지 흐름만 구현한다.

> macOS 또는 사용자가 외장 화면의 Space를 활성화하면, Plugback은 그 순간 보이는 대상 앱의 창만 해당 Space의 저장된 위치로 복원한다.

Plugback은 Space를 생성·삭제·전환·재정렬하거나 화면 사이로 옮기지 않는다. `Desktop N`도 저장하지 않는다.

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

따라서 “Space 자체를 안다”와 “그 안의 창을 안전하게 움직일 수 있다”는 별도 capability다. 전자는 비활성 상태에서도 가능하지만 후자는 활성 상태에서만 가능하다.

## 3. 사용자에게 보일 동작

초기 실험실 버전은 다음처럼 동작한다.

```text
외장 화면 연결
  └─ 현재 활성 Space만 즉시 복원

사용자가 다른 외장 Space로 전환
  └─ Space 변경 알림 수신
      └─ topology 안정화 확인
          └─ 현재 활성 Space에 묶인 대상 앱만 복원

native fullscreen / Split View
  └─ type 4로 감지하고 그대로 둠
```

- 수동 슬롯: 사용자가 각 Space를 연 상태에서 「지금 레이아웃 저장」을 한 번씩 누르면, 방문한 Space의 앱 위치가 기존 프로필에 병합된다.
- 자동 슬롯: 실험실이 켜져 있으면 사용자가 Space를 방문하고 창을 옮길 때 현재 활성 Space의 위치를 후보에 수집한다.
- 복원 모드가 자동이면 연결 직후의 활성 Space와 이후 방문한 Space를 자동 복원한다.
- 복원 모드가 수동이면 「지금 레이아웃 복원」은 현재 활성 Space만 다룬다.
- 전체화면 Space는 존재와 상태만 확인하고 위치·크기·전체화면 속성을 쓰지 않는다.

사용자는 모든 Space를 한 번에 순회하도록 강제받지 않는다. 평소처럼 Space를 열 때 그 Space가 복원된다.

## 4. 절대 지킬 규칙

1. **Space를 쓰지 않는다.** SkyLight 변경 함수, Mission Control UI 조작, 단축키 합성으로 Space를 움직이지 않는다.
2. **전역 번호를 저장하지 않는다.** `Desktop N`, global order, raw SID, CGWindowID는 프로필이나 UserDefaults에 기록하지 않는다.
3. **type `0`만 좌표 복원한다.** type `4`, 알 수 없는 type, `AXFullScreen` 불명은 움직이지 않는다.
4. **Space binding이 있으면 추측하지 않는다.** 현재 Space를 확실히 대응하지 못하면 해당 대상 앱만 건너뛰고 legacy 창 선택으로 내려가지 않는다.
5. **내장 화면을 바꾸지 않는다.** 내장 Space 레코드가 raw snapshot에 포함돼도 저장·이동 대상으로 사용하지 않는다.
6. **기존 기능을 보존한다.** 실험실이 꺼졌거나 private reader가 로드되지 않으면 현재 flat 프로필 동작과 테스트 결과가 그대로다.
7. **오버레이는 먼저 영속화하지 않는다.** 첫 vertical slice는 같은 Plugback 프로세스 안의 분리·재연결만 지원한다.
8. **같은 bundle의 다중 Space 창은 v1에서 추측하지 않는다.** 한 bundle이 서로 다른 Space에 관찰되면 해당 bundle을 unresolved로 둔다.
9. **복원 전 저장을 금지한다.** 재연결 뒤 아직 복원할 binding이 남은 Space를 처음 열었을 때는 복원부터 하고, 그 결과를 어질러진 현재 배치로 수집하지 않는다.
10. **민감한 식별자를 로그에 남기지 않는다.** 진단 출력은 기존처럼 hash와 같음/변경/중복만 쓴다.

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
```

- `runtimeID`와 `windowServerID`는 메모리 밖으로 나가지 않는다.
- `opaqueName`이 비거나 같은 화면에서 중복이면 binding을 만들지 않는다.
- unique name이 같으면 local order가 바뀌어도 같은 Space로 본다. local order는 충돌 진단에만 쓴다.
- 같은 이름이 다른 화면에만 나타나면 stranded로 보고 건너뛴다.
- membership이 0개 또는 2개 이상이면 sticky/불명 상태이므로 unresolved다.

## 6. 모듈과 seam

```text
ActiveSpaceWatcher ──무페이로드 이벤트──▶ PlugbackController
                                              │
                          ┌───────────────────┼──────────────────┐
                          ▼                   ▼                  ▼
                    WindowGateway       SpaceReader       ProfileSlots
                     AX 창 + 임시 ID     안정 snapshot     profile + overlay
                          └───────────────────┬──────────────────┘
                                              ▼
                                        RestoreEngine
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

### WindowGateway

기존 `WindowInfo`에 마지막 AX 열거에서만 유효한 optional `windowServerID`를 붙인다. 실물 `AXWindowGateway`가 `_AXUIElementGetWindow`로 채운다. 저장하지 않으며 join 실패는 nil이다.

전체화면 상태는 Space 경로에서 `windowed | fullscreen | unknown`의 세 값으로 다룬다. 기존 `isFullscreen` 호출은 source compatibility를 유지하되, Space-bound 창은 `unknown`일 때 움직이지 않는다.

### ActiveSpaceWatcher

공개 [`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)을 관찰한다. 이 알림은 payload가 없으므로 callback도 무페이로드이며 controller가 전체 snapshot을 다시 읽는다.

별도 protocol은 만들지 않는다. notification 구독·해제와 실측으로 정할 짧은 후행 debounce만 숨기는 내부 module이면 충분하다. 실험실이 꺼져 있으면 observer도 존재하지 않는다.

### ProfileSlots

overlay는 복원 소스를 고르는 `ProfileSlots`가 소유한다. profile과 overlay가 다른 슬롯에서 섞이지 않도록 manual/auto/candidate의 수명을 함께 움직인다.

| 동작 | profile과 overlay |
|---|---|
| 수동 저장 | 같은 창 선택 결과로 manual 둘을 갱신하고 candidate 둘을 폐기 |
| 수집 | 같은 base에서 candidate 둘을 갱신 |
| 확정 | candidate 둘을 auto로 함께 이동 |
| seed | manual 둘을 auto로 함께 복사 |
| 대상 앱 추가·편집·삭제 | 두 슬롯과 candidate 모두 같은 bundle을 처리 |
| 프로필 삭제 | 해당 화면의 overlay도 전부 삭제 |
| 실험실 끄기 | candidate overlay 폐기, private watcher 중지 |

### RestoreEngine

엔진은 `ResolvedProfile`과 한 번 열거한 `[WindowInfo]`, stable snapshot을 받아 bundle별로 단 하나의 경로를 고른다.

| 조건 | 결과 |
|---|---|
| overlay 없음 | 기존 legacy 경로 |
| regular binding이 현재 외장 Space와 unique하게 일치 | 정확히 join된 창만 복원 |
| binding이 다른 비활성 Space에 있음 | 이번 회차는 대기, Space 활성화 때 재시도 |
| name 소실·중복, stranded, join 0/2+, reader unavailable | 해당 bundle만 `spaceUnavailable` |
| unresolved | 해당 bundle만 `spaceUnavailable` |
| type `4` 또는 fullscreen | 해당 bundle만 `fullscreen` |
| 화면 지문 불일치 | 기존처럼 화면 전체 건너뜀 |

Space binding이 있는 bundle은 같은 실행에서 legacy 경로로 내려가지 않는다.

## 7. 한 회차의 순서

### 연결 직후

```text
1. DisplayWatcher 안정화와 기존 위상 게이트 통과
2. 연결된 외장 화면과 선택된 profile+overlay 확정
3. overlay가 가리키는 regular Space들을 pending으로 표시
4. 현재 활성 Space에 해당하는 binding만 복원
5. 나머지는 사용자가 해당 Space를 활성화할 때까지 유지
```

### Space 활성화

```text
1. ActiveSpaceWatcher 이벤트 압축
2. 화면 목록 동기화
3. 현재 활성 Space가 연속 두 snapshot에서 같은지 확인
4. pending binding이 있으면 복원부터 실행
5. 성공·제자리·fullscreen이면 pending 종료
6. 앱이 꺼져 있거나 reader가 일시 unavailable이면 다음 방문까지 pending 유지
7. 복원 회차가 끝난 뒤에만 자동 슬롯 수집 허용
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

capture·collect·prediction에서 이미 시작된 창 열거가 있으면 restore의 authoritative 열거 전에 끝까지 기다린다. 새 actor 계층 대신 MainActor controller 안의 작은 in-flight counter와 drain만 둔다.

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
- `ProfileSlots`는 manual/auto/candidate profile과 메모리 overlay를 같은 source에서 선택하고 capture·collect·confirm·seed·add·edit·remove 수명에서 함께 이동한다. 기존 JSON schema에는 필드를 추가하지 않았다.
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
- 수동 저장은 같은 AX 열거에서 frame과 Space binding을 함께 잡는다. 재연결 시 binding을 pending으로 만들고 현재 Space만 복원한 뒤, 나머지는 해당 Space 방문 이벤트까지 유지한다.
- Space-aware pass는 앞서 시작한 controller 창 read를 drain하고, 새 창 polling 뒤 authoritative AX 열거 1회 → stable snapshot → planner → 같은 gateway ID로 move 순서를 지킨다. 완료·제자리·fullscreen만 pending에서 제거한다.
- P4 동안에는 profile과 Space overlay가 다른 legacy 후보로 갈리는 것을 막기 위해 Space 실험 경로의 자동 수집을 멈춘다. 현재 Space binding을 함께 수집하는 일은 P5 범위다.
- controller vertical slice, fullscreen, reader unavailable legacy fallback, 창 read drain, 이벤트 압축을 검증했다. 후속 리뷰에서 Space 경로의 최소화 옵션과 수동 복원 모드의 현재 Space 한정 동작을 보강했으며, 두 회귀를 포함한 전체 137개 테스트와 서명된 Debug 앱 빌드가 통과했다.
- 2026-08-29 실기기 게이트에서 다른 외장 화면 B를 연결했을 때 AX 창 열거만 2회 발생하고 이동은 0회여서 저장된 A 화면 배치가 B에 적용되지 않았다.
- A 재연결 뒤 저장된 다른 regular Space를 교란하고 방문하자 1.5초 후 Finder와 Zed가 각각 한 번씩 복원됐다. 같은 Space를 다시 교란해 재방문했을 때는 AX 재열거와 이동이 모두 늘지 않아 pending의 방문별 1회 수명이 확인됐다.
- 활성 Buzz native fullscreen에서 reader는 type `4` 1개, `AXFullScreen=true` 1개, 표준 창 `5/5`의 단일 Space join을 보고했다. 메인 프로세스의 누적 이동은 2회로 유지돼 연결된 상태의 fullscreen 방문에서는 창을 움직이지 않았다.

남은 게이트: 저장 대상 앱이 native fullscreen인 상태에서 A → B → A로 화면을 바꾼 뒤 type `4` 감지와 해당 창 이동 0회를 확인한다. 현재 구현은 fullscreen 상태를 저장하거나 재생성하지 않으며 macOS가 유지한 상태에 개입하지 않는지만 검증한다.

### P5 — 자동 슬롯 수집 통합

기존 `CollectTrigger`와 `ProfileSlots`에 현재 활성 Space binding을 함께 전달한다.

- Space 활성화 직후 pending 복원이 있으면 복원 후에만 수집한다.
- 평상시 방문이면 현재 Space의 기존 대상 앱만 후보에 수집한다.
- 화면 분리와 앱 종료 확정은 창을 다시 읽지 않고 profile+overlay 후보를 함께 기록한다.
- manual/auto 중 더 최근 슬롯이 이길 때 overlay도 같은 슬롯에서 온다.

GO:

- 사용자가 각 Space를 평소처럼 방문·배치한 뒤 분리하면, 재연결 후 방문 순서와 무관하게 각 Space가 자기 위치로 돌아온다.
- 실험실을 끄면 observer와 private read가 모두 멈추고 현재 자동 슬롯 동작으로 돌아간다.

### P6 — 결과 표시와 현재 문서 동기화

실기기 vertical slice가 통과한 뒤에만 사용자 surface를 늘린다.

- `SkipReason.spaceUnavailable`과 필요하면 “Space를 열면 복원됨” 상태 추가
- 카드 표현과 `CardPresentationTests` 갱신
- `CONTEXT.md`, `FUNCTIONAL_SPEC.md`, `ARCHITECTURE.md`, `RESTORE_FLOW.md`, `UNDOCUMENTED_APIS.md` 갱신
- 필요하면 `US-014-active-space-restore.md` 추가

이 단계 전까지 이 기능은 Debug/실험실 검증 경로이며 제품 동작으로 문서화하지 않는다.

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
- name 소실·중복, 다른 화면, type `4`, membership 0/2+는 해당 bundle만 건너뜀
- fullscreen true/unknown은 이동하지 않음
- 같은 화면의 확실한 다른 bundle은 계속 복원
- Space-bound bundle은 legacy로 재선택되지 않음
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
| Mission Control UI 자동화 | 화면 배치와 UI 변경에 취약하고 시각 전환을 숨길 수 없음 | 기본 경로가 아닌 명시적 사용자 실행 도구가 필요할 때 |
| SkyLight private write | OS 버전·보안 설정 의존, 잘못된 Space 이동 위험 | 배포 기능이 아닌 별도 연구 브랜치에서만 |
| raw CGWindow bounds로 비활성 복원 | 이동할 AX 표준 창을 얻지 못해 복원 검증 불가 | 안정적인 CG→AX 역방향 join이 검증될 때 |
| fullscreen·Split View 자동 생성 | pairing·순서·divider를 보장하는 수단 없음 | Apple 공개 capability가 생길 때 |

## 11. 이 브랜치의 완료 정의

`feature/active-space-restore`는 P1–P6을 통과하면 완료다.

- 실험실이 꺼진 기본 동작에 회귀가 없다.
- 같은 프로세스 안에서 외장 화면 분리·재연결 후, 방문한 regular Space의 대상 앱만 복원된다.
- 비활성 Space, 내장 화면, fullscreen/Split View를 자동 조작하지 않는다.
- private read 실패는 crash나 잘못된 이동이 아니라 bundle 단위 건너뜀 또는 기존 동작으로 끝난다.
- 코드, 기능명세, architecture, 복원 흐름, 비공식 API 목록이 같은 경계를 설명한다.
