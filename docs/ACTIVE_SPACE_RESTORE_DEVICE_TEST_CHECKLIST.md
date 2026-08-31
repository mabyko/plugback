# 활성 Space 복원 실기기 체크리스트 (임시)

> 이 문서는 남은 실기기 게이트를 같은 기준으로 반복하기 위한 작업표다.
> 모든 항목이 끝나면 결과만
> [ACTIVE_SPACE_RESTORE_PLAN.md](./ACTIVE_SPACE_RESTORE_PLAN.md)에 옮기고 이 파일은 삭제한다.

- 시작일: 2026-08-31
- 작업 브랜치: `feature/active-space-restore`
- 시작 HEAD: `2c3b1d1`
- A 화면: `PHL 27E2F7901`
- B 화면: `LG ULTRAFINE`
- 현재 상태: 현재 worktree의 새 Release가 `/Applications/Plugback.app`에서 실행 중

## 판정 원칙

- 기존 자동 재배치 1/3은 복원 코어의 실측 증거로 유지한다. 남은 두 회차와 최종 smoke는
  **현재 worktree로 새로 빌드한 Release**에서만 기록한다.
- `SlotSpaceOverlay`는 메모리 전용이다. Release를 교체하거나 Plugback·macOS를 재시작하면 A에서 일반 Space 두 곳을 다시 저장한다.
- 한 A → B → A 회차가 끝날 때까지 Plugback을 종료하지 않는다.
- macOS가 저장된 Space를 스스로 A로 돌려놓은 회차는 회귀 없음으로 기록하되, Plugback의 자동 재배치 성공 횟수에는 넣지 않는다.
- 실패하면 바로 다시 시도하지 않는다. 당시 설정, 화면 구성, 카드 상태와 관찰 결과를 먼저 적는다.
- B에서 한 저장·수집은 B 프로필에만 속해야 한다. A 프로필의 통과 근거로 사용하지 않는다.

## 0. 새 Release 기준선

현재 소스의 최종 실기기 판정을 시작하기 전에 한 번만 수행한다.

- [x] 전체 테스트 통과
- [x] Release 빌드 성공
- [x] `/Applications/Plugback.app` 교체
- [x] 기존 Plugback 종료 후 새 Release 실행
- [x] 실행 경로가 `/Applications/Plugback.app/Contents/MacOS/Plugback`인지 확인
- [x] 손쉬운 사용 권한 정상
- [x] 카드 앱 행에서 복원 예측 점·라벨이 사라졌는지 확인
- [x] 저장된 Space 그룹, 체크박스, 실제 복원 결과 스트립은 그대로 보이는지 확인

기록:

- 빌드한 commit/worktree: `e5f3d98 + unresolved binding 범위 보존 변경`
- 빌드 시각: `2026-08-31 15:59 KST`
- 실행 PID: `87031`
- 테스트 결과: `Swift 패키지 180/180 · 앱 9/9 통과`

## 1. A 기준 배치 다시 만들기

Release 재실행 뒤 메모리 overlay를 다시 만드는 단계다.

설정:

- 자동 복원: ON
- 자동 슬롯: ON
- 자동 슬롯 반영 방식: `분리할 때 저장`
- 일반 Space 복원: ON
- 전체 화면 복원: OFF — 먼저 regular Space만 분리해서 확인한다

절차:

- [ ] A 연결
- [ ] A에 일반 Space 두 곳 준비
- [ ] 첫 번째 Space에서 창 위치를 정하고 `지금 레이아웃 저장`
- [ ] 두 번째 Space에서 창 위치를 정하고 `지금 레이아웃 저장`
- [ ] 첫 번째 Space를 방문해 3초 머무름
- [ ] 두 번째 Space를 방문해 3초 머무름
- [ ] 카드에 두 Space 그룹이 보임
- [ ] 카드에 저장 대기 후보가 보임
- [ ] A 분리로 후보 확정

기록:

- 첫 번째 Space 앱: `________________`
- 두 번째 Space 앱: `________________`
- 자동 슬롯 확정 시각: `________________`
- 특이사항: `________________`

단일 외장 보충 게이트 (`LG HDR 4K`, 2026-08-31):

- [x] 일반 Space 두 곳 배치·수동 저장
- [x] 두 Space 각각 3초 방문
- [x] 카드의 두 Space 그룹·저장 대기 후보 확인
- [x] 화면 분리로 후보 확정 (`2026-08-31 16:38:08 KST`)
- [ ] 내장 화면 교란 뒤 재연결 복원 확인

관찰: 재연결 콜백은 실행됐지만 Space drag 호출은 0회였다. 재연결 직후에는 창 이동이
없었고, 내장 화면에서 교란된 Space를 방문하자 Aside가 외장 화면으로 복원됐다. 저장된
Space가 macOS에 의해 이미 외장 화면으로 돌아왔는지는 카드 상태로 판정한다.

판정: 카드에서 Space 1 `현재`, Space 2 `방문 시 복원`을 확인해 두 저장 Space는 macOS가
외장 화면으로 되돌린 것으로 판정했다. 이후 수동 복원·수동 저장이 섞인 회차는 자동 방문
복원 판정에서 제외하고, 두 Space를 다시 저장해 새 회차를 시작했다.

새 회차 자동 슬롯 확정: `2026-08-31 17:51:51 KST` · 대상 앱 4개.

단일 외장 최종 판정: 두 Space 모두 재연결·방문 시 처음부터 저장 위치였다. 방문 복원
경로는 10회 진입했지만 `MissionControlSpaceRelocator.relocate`와
`AXWindowGateway.move`는 모두 0회였다. macOS 자체 복구로 시각적 회귀는 없었으나,
Plugback의 Space·창 이동 성공 횟수에는 포함하지 않는다. A → B → A 게이트는 보류한다.

## 2. 게이트 A — 자동 regular Space 재배치 3/3

기존 통과 기록은 1/3이다. 새 Release에서는 아래 두 회차를 통과해 합계 3/3을 만든다.
첫 회차는 두 regular Space의 후보가 함께 확정되는지도 같이 확인한다.

각 회차 절차:

1. A의 두 일반 Space를 각각 방문하고 창 하나를 조금 움직인다.
2. Mission Control을 열었다면 닫고 3초 기다린다.
3. 카드의 저장 대기 상태를 확인한 뒤 A를 분리한다.
4. B를 연결해 실제 사용처럼 창과 Space를 재배치한다. A 검증을 위해 B에서 수동 저장할 필요는 없다.
5. B를 분리하고 A를 연결한다.
6. Mission Control을 직접 열지 않고 20초 기다린다.
7. 현재 Space의 창 위치를 확인한다.
8. 다른 저장 Space를 각각 한 번 방문해 창 위치를 확인한다.

통과 기준:

- Plugback이 Mission Control을 잠깐 열고, 내장 화면에 남은 **저장된 A Space**를 A로 옮긴다.
- 현재 Space의 창은 먼저 복원되고 다른 Space의 창은 방문할 때 각각 한 번 복원된다.
- B 전용 Space와 관계없는 내장 Space는 움직이지 않는다.
- Mission Control drag 뒤 화면 구성과 창 membership이 안정된 상태로 끝난다.

| 회차 | 두 Space 후보 함께 확정 | macOS가 스스로 복귀 | Plugback Mission Control 동작 | 현재 Space 복원 | 방문 Space 복원 | 관계없는 Space 무동작 | 판정 |
|---|---|---|---|---|---|---|---|
| 기존 1 | 별도 실측에서 확인 | 아니요 | 확인 | 확인 | 확인 | 확인 | 통과 |
| 추가 2 |  |  |  |  |  |  |  |
| 추가 3 |  |  |  |  |  |  |  |

회차별 메모:

- 추가 2: `________________`
- 추가 3: `________________`

## 3. 게이트 B — 자동 슬롯 OFF 무수집

목적은 자동 슬롯과 복원 범위가 독립적인지 확인하는 것이다. 자동 슬롯이 OFF여도
일반 Space 복원이 ON이면 **수동 슬롯**으로 복원되는 것이 정상이다.

준비:

- [ ] A 연결
- [ ] 자동 슬롯 ON 상태에서 두 일반 Space를 원하는 기준 위치로 수동 저장
- [ ] 자동 슬롯 OFF
- [ ] 일반 Space 복원 ON 유지
- [ ] 자동 복원 ON 유지

교란과 확인:

- [ ] 두 Space에서 창 위치를 변경
- [ ] 저장된 일반 Space 하나를 내장 화면으로 이동
- [ ] Mission Control을 닫고 3초 이상 기다림
- [ ] `지금 레이아웃 저장`을 누르지 않음
- [ ] 저장 대기 후보나 새 자동 저장 시각이 생기지 않음
- [ ] A 분리 후 재연결
- [ ] 교란 배치가 아니라 수동 저장 기준으로 Space와 창 위치가 복원됨

통과 기준:

- Space 방문·창 이동·Mission Control 닫힘이 후보와 자동 슬롯을 바꾸지 않는다.
- 기존 자동 슬롯 값이 파일에 남아 있어도 OFF 동안 복원 소스로 선택되지 않는다.
- 수동 슬롯을 사용한 일반 Space 복원은 정상 동작한다.

기록:

- 수동 저장 시각: `________________`
- 교란 내용: `________________`
- 재연결 결과: `________________`
- 판정: `통과 / 실패`

## 4. 게이트 C — Split View fail-closed

single native fullscreen 복원은 이미 3/3 통과했다. 이 게이트는 창 두 개가 함께 있는
Split View를 single fullscreen으로 잘못 복원하지 않는지 확인한다.

설정:

- 자동 슬롯: ON
- 전체 화면 복원: ON
- 일반 Space 복원: OFF — Split View 경로만 분리해서 본다
- Split View의 두 앱: 대상 앱 체크 ON

절차:

- [ ] A에서 앱 두 개로 Split View 생성
- [ ] Split View를 방문해 3초 머무름
- [ ] 자동 수집 신호가 들어온 것을 확인
- [ ] A 분리
- [ ] B 연결 후 실제 사용처럼 배치
- [ ] B 분리
- [ ] A 연결 후 20초 기다림
- [ ] Split View가 내장 화면에 남았다면 한 번 방문

통과 기준:

- Split View 두 창에 대한 fullscreen 해제·재진입이 없다.
- 두 창에 대한 화면 이동이 없다.
- Split View가 macOS가 둔 위치와 상태를 그대로 유지한다.
- 엄격한 판정은 해당 창에 대한 `AXWindowGateway.setFullscreen` 0회와 move 0회다.

기록:

- 사용 앱 두 개: `________________`
- 화면에서 본 동작: `________________`
- fullscreen write 횟수: `________________`
- move 횟수: `________________`
- 판정: `통과 / 실패`

## 5. 이미 통과한 항목의 Release smoke test

아래는 새 설계 게이트를 다시 3회 수행하지 않고, 새 Release에서 한 번씩만 회귀 확인한다.

- [ ] 방문하지 않은 처음 본 single fullscreen 자동 수집
- [ ] A → B에서 A fullscreen이 B로 잘못 이동하지 않음
- [ ] A 재연결 뒤 해당 fullscreen 방문 시 일반 창 전환 → A 이동 → fullscreen 재생성
- [ ] 종료한 fullscreen 앱은 과거 fullscreen binding에서 제거되고 복원하지 않음

기록: `________________`

## 6. 종료 조건

- [ ] 자동 regular Space 재배치 합계 3/3
- [ ] 자동 슬롯 OFF 무수집 통과
- [ ] Split View fullscreen write 0회·move 0회 통과
- [ ] 새 Release smoke test 통과
- [ ] 결과를 `ACTIVE_SPACE_RESTORE_PLAN.md`에 옮김
- [ ] 이 임시 체크리스트 삭제
