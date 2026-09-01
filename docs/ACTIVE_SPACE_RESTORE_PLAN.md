# 안내형 Space 복원 계획

## 상태

2026-09-01 기준 구현 완료, 실기기 확인 대기.

이 문서는 이전의 「일반 Space 자동 복원」과 「전체 화면 복원」 계획을 대체한다. 실패한 private write·Mission Control 합성 실험의 상세 근거는 다음 조사 문서와 git 이력에 남긴다.

- [일반 Space 화면 간 이동 조사](./research/regular-space-relocation-between-displays.md)
- [Mission Control 외장 화면 조사](./research/mission-control-spaces-on-external-screens.md)
- [native fullscreen 조사](./research/native-fullscreen-space-restore-and-ordering.md)

## 1. 목표

외장 화면에 저장한 일반 Space가 재연결 뒤 다른 화면에 남았을 때 다음 흐름을 제공한다.

1. Plugback이 대상 앱이 묶인 잔류 Space를 읽기 전용으로 감지한다.
2. 카드가 출발 화면과 목적 화면을 알려준다.
3. 사용자가 Mission Control에서 그 Space를 한 번 옮긴다.
4. Plugback이 Mission Control 닫힘 뒤 목적 화면 이동을 확인한다.
5. 창이 있는 Space라면 사용자가 그 Space를 한 번 연다.
6. Plugback이 그 Space의 대상 표준 창을 저장 좌표로 자동 복원한다.

사용자 입력은 Space 이동 한 번과, 비활성으로 옮겨진 경우 방문 한 번이다. 앱은 창 위치 복원만 자동화한다.

## 2. 하지 않는 것

- 목적 화면에 처음부터 있던 비활성 Space를 방문할 때마다 복원
- Space 생성·삭제·화면 간 이동·순서 변경
- Mission Control 열기, pointer·keyboard 입력 합성
- SkyLight write 또는 Dock AX drag
- native fullscreen 해제·이동·재진입
- Split View 복원
- 전체화면·일반 Space 복원 범위 토글
- 판정 실패 때 평면 창 복원으로 강등

전체화면 창은 기존처럼 건너뛴다. 일반 Space recovery는 새 복원을 시작한 순간 실제로 다른 화면에 남은 Space에만 생긴다.

## 3. 결정 근거

### 읽기는 쓸 수 있다

stable Space snapshot은 화면별 Space 종류·현재 여부·opaque name·로컬 순서와 AX 창의 임시 WindowServer membership을 한 회차에서 읽을 수 있다. opaque name이 snapshot 전체에서 하나일 때만 저장 identity로 쓴다.

### 쓰기는 제품에 쓸 수 없다

빈 Space의 bridged private move는 제한된 실험에서 왕복했지만, 앱 창이 있는 Space에서는 지연 이동, 검은 화면, Mission Control thumbnail 소실, orphan Space가 관찰됐다. Mission Control 합성 drag는 사용자 입력을 빼앗고 Dock의 비공개 AX tree·animation에 의존한다.

### 비활성 창은 바로 복원할 수 없다

목적 화면으로 옮겨졌지만 비활성인 Space의 창은 AX 표준 창 열거에서 안정적으로 보이지 않는다. 숨은 창을 추측해 움직이지 않고, 사용자가 한 번 열어 authoritative 열거가 가능해진 뒤 복원한다.

따라서 가장 작은 안전한 제품 흐름은 read-only 감지 + 사용자 이동 + 이벤트 기반 창 복원이다.

## 4. 상태 모델

`RestoreSession`은 `(목적 화면 ID, 저장 opaque name)`을 recovery identity로 쓴다.

| 관찰 결과 | recovery 단계 | 사용자 표시 | 다음 입력 |
|---|---|---|---|
| 다른 화면의 유일한 regular Space | `move(sourceScreenID)` | `출발 → 목적`, Mission Control 이동 안내 | Mission Control 닫힘 |
| 목적 화면의 비활성 regular Space, 대상 창 있음 | `visit` | 목적 화면에서 이 Space를 열면 자동 복원 | 활성 Space 변화 |
| 목적 화면의 현재 regular Space | 완료 처리 | 창 위치 복원 후 안내 제거 | 없음 |
| missing·중복·unsupported·snapshot 없음 | `unavailable` | 현재 상태를 확실히 확인할 수 없음 | 다음 명시적 복원 또는 상태 이벤트 |

새 `restore`는 기존 recovery를 모두 버리고 현재 관찰에서 `.stranded`인 저장 Space만 등록한다. `.inactive`로 시작한 Space는 등록하지 않는다. `recheck`는 recovery가 없으면 창이나 Space를 읽지 않는다.

## 5. 구성 요소 계약

### DesktopObservation

`sample(of:includeSpaces:)`가 관찰 시작 sequence, AX 창과 그 창 ID로 만든 Space availability를 한 값으로 돌려준다. reader 부재·의도적 생략은 유효한 flat 관찰이고, reader가 stable snapshot을 만들지 못한 `.unavailable`과 구별된다. 둘을 따로 읽는 API는 없다. `drain()`은 복원보다 먼저 시작한 카드·수집·저장 열거가 끝날 때까지 기다려 임시 창 ID를 섞지 않게 한다.

### RestoreSession

- `restore`: 이전 recovery 취소 → legacy windowless 처리 → authoritative sample → stranded recovery 생성 → 현재 복원 가능한 창 처리
- `recheck`: recovery가 있을 때만 sample → `move/visit/current/unavailable` 재판정 → current recovery의 bundle만 복원
- `cancel`: 저장·대상 변경·프로필 삭제·복원 소스 변경 때 호출

`restore/recheck`는 복원 결과만 반환한다. recovery는 반환값에 복제하지 않고 세션의 읽기 전용 상태로만 제공한다. ProfileSlots나 UI 상태를 소유하지 않으며, 컨트롤러가 선택한 같은 슬롯의 `Profile + Space overlay`만 받는다.

### RestoreEngine

일반 복원과 recovery의 마지막 창 복원을 같은 엔진에서 처리한다. binding이 있는 앱은 snapshot 판정이 실패해도 legacy 선택으로 내려가지 않는다. 전체화면 상태는 읽어서 건너뛸 뿐 쓰지 않는다.

### PlugbackController

MissionControlWatcher 하나를 소유한다. Mission Control 닫힘과 활성 Space 변화가 오면 다음 순서를 지킨다.

1. recovery가 있으면 `RestoreSession.recheck`.
2. 이벤트 직후 stale snapshot 가능성 때문에 recovery가 남으면 정착 간격 뒤 한 번 더 확인.
3. recovery가 끝난 뒤에만 자동 슬롯 수집.
4. 한 sample에서 Space 그룹·구성 차이·저장하지 않는 앱 projection 갱신.

자동 모드는 연결할 때 recovery를 시작한다. 수동 모드는 버튼·단축어가 시작한다. 이미 시작한 recovery는 두 모드 모두 Mission Control 닫힘과 방문 이벤트로 자동 진행한다.

### 카드

저장된 regular Space만 `Space N` 행으로 보여준다. `N`은 저장 당시 외장 화면 안 순서이며 identity가 아니다.

- 잔류: `이동 필요` + `출발 화면 → 목적 화면`
- 이동 뒤 비활성: `열면 복원` + 목적 화면 방문 안내
- 현재: `현재`
- 판정 불가: fail-closed 설명

처음부터 목적 화면에 있던 비활성 Space에는 방문 안내를 붙이지 않는다.

## 6. 데이터 경계

Space overlay는 프로세스 메모리에만 있고 JSON 프로필에는 기록하지 않는다. 저장되는 프로필 형식과 `#auto` 슬롯 키는 바꾸지 않는다.

`SpaceBinding`은 둘뿐이다.

- `.regular(SpaceHint)`
- `.unresolved(reason)`

전체화면 binding과 fullscreen 후보 목록은 없다. `SpaceReader`는 전체화면 type을 read-only로 구분해 일반 Space로 오인하지 않게 한다.

## 7. 안전 불변식

1. 제품 경로에서 Space write와 합성 입력은 0회다.
2. native fullscreen 상태 write는 0회다.
3. 같은 sample의 창 ID와 snapshot만 함께 쓴다.
4. binding 판정 실패는 무동작이며 legacy fallback이 아니다.
5. 처음부터 inactive인 Space는 recovery가 아니다.
6. recovery가 남아 있는 동안 자동 수집하지 않는다.
7. 새 저장·대상 편집·프로필 삭제는 옛 recovery를 취소한다.
8. 내장 화면은 안내에 필요한 Space 소속·이름만 읽으며 창 배치를 저장하거나 바꾸지 않는다.

## 8. 구현 순서와 결과

### P1 · 제거 — 완료

- 일반 Space·전체 화면 복원 설정과 UserDefaults key 제거
- fullscreen capture candidate·binding·복원·`setFullscreen` 제거
- `SpaceRestoreScope`, `restoreAll`, `restoreVisited` 제거

### P2 · observation 단일화 — 완료

- `DesktopObservation.Sample(windows, spaceAvailability?)` 도입 — flat 관찰과 snapshot 실패를 구분
- 저장·수집·카드·복원이 같은 API 사용
- authoritative 복원 전 `drain` 유지

### P3 · recovery 상태 전이 — 완료

- `RestoreSession.restore/recheck/cancel` 도입
- stranded로 시작한 Space만 recovery 생성
- 대상 앱이 없는 Space는 recovery에서 제외
- `move → visit → current/complete`와 fail-closed 구현

### P4 · 이벤트 배선 — 완료

- MissionControlWatcher를 컨트롤러 하나가 소유
- recovery recheck를 자동 수집보다 먼저 실행
- 자동·수동 모두 시작된 recovery를 이어감

### P5 · 카드·설정 — 완료

- 설정의 두 복원 토글 제거
- 전체 화면 그룹 제거
- 출발·목적 화면 안내와 방문 안내 추가

### P6 · 검증 — 자동 검증 완료

- 패키지 단위 테스트: 158개 통과
- 앱 타깃 단위 테스트: 12개 통과
- Release 앱 빌드: 통과
- 실기기 안내 흐름: [체크리스트](./ACTIVE_SPACE_RESTORE_DEVICE_TEST_CHECKLIST.md)에 따라 확인 필요

## 9. 최소 자동 테스트

- stranded → Mission Control 이동 뒤 inactive → 방문 뒤 current → 창 복원·완료
- 처음부터 inactive → recovery 없음, 방문해도 자동 복원 없음
- snapshot 불가 → binding 앱 평면 복원 없음
- snapshot 불가 중 저장·대상 추가·수집 → 기존 프로필·Space overlay·후보·수집 시각 보존
- legacy 프로필 → 기존 창 복원 유지
- 카드 projection → 출발·목적 이름, active recovery에만 방문 안내
- 겹친 카드 projection → 나중에 시작한 observation보다 늦게 끝난 예전 sample 폐기
- 컨트롤러 → Mission Control 닫힘과 활성 Space 이벤트가 한 recovery를 이어감
- fullscreen Space는 저장 regular 목록에서 제외, fullscreen 창은 건너뜀
- 앞선 observation을 drain한 뒤 authoritative sample 실행

## 10. 실기기 완료 조건

1. 저장 Space를 내장 화면으로 옮긴 뒤 자동 또는 수동 복원을 시작하면 정확한 출발·목적 화면이 보인다.
2. 사용자가 그 Space를 외장 화면으로 옮기고 Mission Control을 닫으면 `열면 복원`으로 바뀐다.
3. 한 번 열면 대상 표준 창만 저장 좌표로 복원되고 안내가 사라진다.
4. 처음부터 외장 화면에 있던 비활성 Space를 열어도 Plugback이 임의 복원하지 않는다.
5. 전체화면·Split View와 대상 아닌 앱은 변하지 않는다.
6. Space write, 합성 입력, `AXFullScreen` write가 0회다.

## 11. 보류한 대안

| 대안 | 보류 이유 | 다시 볼 조건 |
|---|---|---|
| SkyLight whole-Space write | 앱 창 포함 Space에서 orphan·지연 이동 | 공개 API가 생기거나 OS 계약이 문서화됨 |
| Mission Control 합성 drag | 사용자 입력 탈취, 비공개 Dock tree·animation 의존 | 사용자가 명시적으로 자동 조작을 원하고 신뢰성 게이트를 통과함 |
| 모든 inactive Space 방문 복원 | 사용자의 평소 Space 이동을 덮어씀 | 별도 제품 요구와 명시적 opt-in이 생김 |
| native fullscreen 재생성 | private write, 순서·Split View 보장 불가 | 공개 상태 변경 API와 명확한 제품 요구가 생김 |
| 주기 polling | 유휴 비용과 끝없는 상태 추적 | 이벤트가 실기기에서 반복 누락된다는 측정 근거가 생김 |
