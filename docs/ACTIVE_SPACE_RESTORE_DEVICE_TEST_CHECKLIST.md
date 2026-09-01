# 활성 Space 복원 실기기 체크리스트 (임시)

> 이 문서는 남은 실기기 게이트를 같은 기준으로 반복하기 위한 작업표다.
> 모든 항목이 끝나면 결과만
> [ACTIVE_SPACE_RESTORE_PLAN.md](./ACTIVE_SPACE_RESTORE_PLAN.md)에 옮기고 이 파일은 삭제한다.

- 시작일: 2026-08-31
- 작업 브랜치: `feature/active-space-restore-try-2`
- 시작 HEAD: `2c3b1d1`
- A 화면: `PHL 27E2F7901`
- B 화면: `LG ULTRAFINE`
- 현재 상태: Release `/Applications/Plugback.app`은 유지하고, 서명된 probe 빌드를 `/Applications/Plugback Debug.app`으로 별도 설치함
- Debug 표식: 앱 이름 `Plugback Debug` · Dock/Finder 아이콘 파란 `D` 배지 · 메뉴바 기존 glyph의 작은 벌레 배지
- 구현 검증: Swift 패키지 179/179 · 앱 10/10 · Release build 통과, Release private-write marker 없음

> 2026-09-01 재설정: 기존 체크·1/3 기록은 제거된 Mission Control 합성 drag 구현의
> 역사적 근거일 뿐 새 경로의 통과 횟수로 세지 않는다. 제품에는 relocator seam과 구현이
> 없다. 아래 게이트 A는 명시적 DEBUG 희생용 probe로만 수행하는 qualification이다.
> 빈 Space 왕복은 통과했지만 앱 창 포함 회차에서 지연 이동과 orphan Space가 발생했다.
> whole-Space write는 Release·자동 복원·Debug 설정 UI에 연결하지 않는다.

## 판정 원칙

- 기존 자동 재배치 1/3은 이전 복원 코어의 실측 증거로만 유지한다. 새 3회와 최종 smoke는
  **현재 worktree로 새로 빌드한 Release**에서만 기록한다.
- `SlotSpaceOverlay`는 메모리 전용이다. Release를 교체하거나 Plugback·macOS를 재시작하면 A에서 일반 Space 두 곳을 다시 저장한다.
- 한 A → B → A 회차가 끝날 때까지 Plugback을 종료하지 않는다.
- macOS가 저장된 Space를 스스로 A로 돌려놓은 회차는 회귀 없음으로 기록하되, Plugback의 자동 재배치 성공 횟수에는 넣지 않는다.
- 실패하면 바로 다시 시도하지 않는다. 당시 설정, 화면 구성, 카드 상태와 관찰 결과를 먼저 적는다.
- B에서 한 저장·수집은 B 프로필에만 속해야 한다. A 프로필의 통과 근거로 사용하지 않는다.

## 0. 새 Release 기준선

현재 소스의 최종 실기기 판정을 시작하기 전에 한 번만 수행한다.

- [ ] 전체 테스트 통과
- [ ] Release 빌드 성공
- [ ] `/Applications/Plugback.app` 교체
- [ ] 기존 Plugback 종료 후 새 Release 실행
- [ ] 실행 경로가 `/Applications/Plugback.app/Contents/MacOS/Plugback`인지 확인
- [ ] 제품 소스에 Space relocator와 Mission Control 입력 합성이 없는지 확인
- [ ] 손쉬운 사용 권한 정상
- [ ] 카드 앱 행에서 복원 예측 점·라벨이 사라졌는지 확인
- [ ] 저장된 Space 그룹, 체크박스, 실제 복원 결과 스트립은 그대로 보이는지 확인

기록:

- 이전 구현 빌드: `e5f3d98 + unresolved binding 범위 보존 변경`
- 이전 빌드 시각: `2026-08-31 15:59 KST`
- 이전 실행 PID: `87031`
- 이전 테스트 결과: `Swift 패키지 180/180 · 앱 9/9 통과`
- 새 빌드/실행 기록: `________________`

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

이전 구현 관찰: 재연결 콜백은 실행됐지만 Space drag 호출은 0회였다. 재연결 직후에는 창 이동이
없었고, 내장 화면에서 교란된 Space를 방문하자 Aside가 외장 화면으로 복원됐다. 저장된
Space가 macOS에 의해 이미 외장 화면으로 돌아왔는지는 카드 상태로 판정한다.

판정: 카드의 live 상태에서 Space 1은 current, Space 2는 목표 화면의 inactive로 확인했고,
당시 Space 2에는 실제 방문 복원도 남아 있었다. 이후 수동 복원·수동 저장이 섞인 회차는
자동 방문 복원 판정에서 제외하고, 두 Space를 다시 저장해 새 회차를 시작했다.

새 회차 자동 슬롯 확정: `2026-08-31 17:51:51 KST` · 대상 앱 4개.

이전 구현의 단일 외장 최종 판정: 두 Space 모두 재연결·방문 시 처음부터 저장 위치였다. 방문 복원
경로는 10회 진입했지만 `MissionControlSpaceRelocator.relocate`와
`AXWindowGateway.move`는 모두 0회였다. macOS 자체 복구로 시각적 회귀는 없었으나,
Plugback의 Space·창 이동 성공 횟수에는 포함하지 않는다. A → B → A 게이트는 보류한다.

## 2. 게이트 A1 — 빈 Space whole-Space bridge 3/3 (완료)

2026-09-01, build `25G83`의 서명된 Debug 앱에서 빈·비활성 source tail Space를 direct bridged
operation으로 목적지 끝에 보냈다가 원래 source index로 되돌리는 왕복을 3회 수행했다. 매 회차
`이동 확인 · 원위치 복귀 확인 · Dock 유지`였고 baseline이 정확히 복구됐다. Mission Control 표시,
합성 입력, Space 생성·삭제, retry는 없었다.

CLI 진단은 계속 빈 Space만 받는다. read-only `--space-probe` JSON의 `sidToken`·`displayToken`으로
다음처럼 실행한다.

```text
Plugback --space-relocation-probe <sidToken> <displayToken> --confirm-empty-sacrificial-space
```

CLI는 `25G83` 외 빌드, 불안정 topology, layer `0` WindowServer 창 membership, 창 메타데이터 누락,
ABI 불일치를 write 전에 거절한다. Dock·Finder desktop·WindowServer·알림 센터의 비표준 layer 창은
빈 Space 판정에서 제외한다.

실측은 exact-build에서 class·initializer encoding을 확인한
`SLSBridgedMoveManagedSpaceToDisplayIndexOperation`만 사용했다. exported
`SLSMoveManagedSpaceToDisplayIndex` raw wrapper는 같은 bridge 또는 적용 ACK가 없는 one-way
fallback으로 가므로 더 안전한 semantics가 없어 실행 후보에서 제외했다.

각 회차 절차:

1. baseline stable snapshot 두 회로 SID·opaque name·display·order·kind·current·layer `0` window membership을 기록한다.
2. 빈 희생용 Space를 destination tail로 한 번 이동하고 8초 안의 stable snapshot을 확인한다.
3. 같은 SID를 원래 source index로 한 번 되돌리고 baseline 복귀를 확인한다.
4. no-op·오이동·Dock 재시작·다른 topology 변경·역복구 실패 중 하나라도 있으면 즉시 중단한다.

통과 기준:

- 같은 SID·opaque name이 A → B → A로 왕복한다.
- 다른 Space의 display·상대 순서·current와 모든 관찰 layer `0` window membership이 baseline과 같다.
- Mission Control 표시, 합성 키보드·마우스 입력, Space create/destroy, 자동 retry가 0회다.
- 빈 Space 3/3만으로는 제품에 연결하지 않는다. 아래 앱 창 포함 게이트 실패로 제품 후보를 닫았다.

| 후보 | 빌드 | 왕복 1 | 왕복 2 | 왕복 3 | baseline 복귀 | 판정 |
|---|---|---|---|---|---|---|
| direct bridged op | `25G83` | 통과 | 통과 | 통과 | 3/3 | 자동 검증 통과 |
| raw wrapper | `25G83` | 미실행 | 미실행 | 미실행 | — | 후보 제외 |

## 2.1. 게이트 A2 — 앱 창 포함 시각 확인 (실패 · 종료)

2026-09-01, 내장 화면의 macOS `데스크탑 2`/Buzz를 희생용으로 허용했다. 중간 topology 항목은
Obsidian fullscreen이었다. 외장 `데스크탑 5`/Mail 회차는 실행하지 않았다.

관찰:

1. direct bridged move 뒤 Mission Control에서 이동이 보이지 않았고, 내장 `데스크탑 2`는 검정 화면이 됐다.
2. 첫 `원위치 복귀`는 거절됐고 잠시 뒤 재실행은 topology baseline 복귀와 Dock 유지로 `통과`했다.
3. 통과 뒤에도 대상 SID와 Buzz 창 프레임이 외장 화면 끝으로 지연 이동했다. Buzz 창은 그 비활성 SID에
   단일 membership을 유지하면서 다른 외장 Space에서도 계속 보였다.
4. SkyLight에는 외장 type `0` Space가 4개였지만 Mission Control에는 3개만 보여 대상 SID가 orphan이 됐다.
5. Debug 앱을 종료하고 Dock을 한 번 재시작하자 네 번째 thumbnail이 다시 나타났다. 사용자가 이를
   Mission Control로 내장 화면에 직접 옮긴 뒤 membership과 창 프레임이 모두 내장 화면으로 돌아왔고,
   화면별 regular 수는 내장 2·외장 3으로 복구됐다. Buzz의 정확한 최종 좌표는 사용자가 조정했으므로
   baseline 좌표 근거로 쓰지 않는다.

판정: 두 번 같은 stable topology를 읽은 것은 populated Space operation의 완료·지속성을 증명하지
못한다. 자동 rollback도 transient baseline을 성공으로 오판했다. 앱 창 포함 write 경로와 Debug 설정
패널을 제거하고, 빈 Space 전용 CLI 외에는 whole-Space write를 노출하지 않는다.

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

- [ ] 제품 Mission Control 입력 0회·Space relocation 호출 0회 smoke 통과
- [ ] whole-Space bridge를 다시 연결하려면 DEBUG 희생용 왕복 3/3 통과
- [ ] 자동 슬롯 OFF 무수집 통과
- [ ] Split View fullscreen write 0회·move 0회 통과
- [ ] 새 Release smoke test 통과
- [ ] 결과를 `ACTIVE_SPACE_RESTORE_PLAN.md`에 옮김
- [ ] 이 임시 체크리스트 삭제
