# 자동·안내형 복원 흐름

## Plugback

이 문서는 외장 화면 연결이나 복원 버튼 한 번이 창 이동까지 이어지는 순서만 설명한다. 조건의 기준은 [FUNCTIONAL_SPEC.md](./FUNCTIONAL_SPEC.md), 용어는 [CONTEXT.md](../CONTEXT.md)를 따른다.

Plugback이 직접 바꾸는 것은 대상 앱의 표준 창 위치와, 실험실 옵션이 켜졌을 때의 앱 실행·창 열기 요청뿐이다. Space 화면 소속, Space 순서, native fullscreen 상태는 쓰지 않는다.

---

## A · 이벤트 층

복원 요청을 새로 시작하는 입력은 셋이다.

1. `DisplayWatcher`가 안정된 화면 조합의 변화를 알리고, 복원 모드가 자동이며, 새 작업 환경의 저장본이 있다.
2. 사용자가 카드 버튼이나 시스템 단축어로 「지금 복원」을 실행한다.
3. 사용자가 「남은 창 복원」으로 확인 필요·대기 항목을 재개한다 (기존 요청 안에서 사용자 요청으로 취급).

`ActiveSpaceWatcher`와 `MissionControlWatcher`는 새 요청을 만들지 않는다. 진행 중 요청의 방문 대기·이동 안내 항목만 다시 판정하고, 그 뒤 수집 신호로 쓴다. 잠금 해제 알림은 잠금 보류 항목만 재개한다.

```
화면 조합 변화 ── DisplayWatcher ─┐  (떠나는 환경 확정 → 새 환경 선택 → 자동이면 요청)
복원 버튼·단축어 ─────────────────┼─▶ PlugbackController.performRestore → RestoreSession.start
남은 창 복원 ─────────────────────┘                                        └ RestoreSession.resume(.user)
Mission Control 닫힘 ─────────────┐
활성 Space 변화 ──────────────────┼─▶ RestoreSession.resume(.waiting) → 수집
잠금 해제 ────────────────────────┘─▶ RestoreSession.resume(.unlock)
```

DisplayWatcher 안에서는 원시 화면 이벤트 압축, 유효 화면 판정, 잠자기 억제·잠금 미루기가 먼저 끝난다(F-01). 원시 변경 신호가 오면 수집은 안정화까지 멈춘다.

---

## B · 요청 층

컨트롤러는 작업 환경과 복원 소스를 고르고, `RestoreSession`은 한 요청의 수명을 관리한다.

```
PlugbackController
  ├─ 화면 목록·권한·개별 Spaces 조건 동기화
  ├─ 현재 작업 환경의 마지막 저장본 선택 (소스 고정)
  └─ RestoreSession.start(origin: 자동 | 사용자)
       ├─ 이전 요청의 남은 작업 취소
       ├─ DesktopObservation.drain
       ├─ 같은 회차의 (표준 창, stable Space snapshot) 한 번 읽기
       ├─ RestoreEngine.plan — 저장 창마다 결정
       ├─ 실행·생성이 필요하면 (옵션·닫힌 환경 통과분만) 요청 뒤 다시 읽고 다시 plan
       └─ 이동 실행 — 이동마다 요청 유효성·잠금·사용자 조작 확인
```

저장 창 하나의 결정은 다음 순서다.

| 확인 | 실패·대기 시 결과 |
|---|---|
| 앱이 제외되지 않았나 | 결과 없음 (진행 중 제외됐으면 취소) |
| 화면 지문이 맞나 | 화면 통째 건너뜀 |
| 같은 환경에서 닫힌 자리인가 | 「이 환경에서 닫아 건너뜀」 |
| 저장 Space가 현재인가 | 비활성 → 방문 대기, 잔류 → 이동 안내, 없음·불명 → 확인 필요 |
| 대응할 창이 있나 | 연결 우선 → 직접 지정(ON·모호) 확인 필요 → 전체 이동 거리 최소 배정 |
| 창이 없으면 | 옵션 OFF → 건너뜀 사유, 옵션 ON·다른 환경에서 닫힘 → 실행·생성, 닫힌 환경 불명 → 확인 필요 |
| 이동 직전 | 요청 무효 → 중단, 잠금·판정 불가 → 잠금 보류, 자동 요청의 사용자 조작 창 → 건너뜀 |
| 이동 뒤 | 실제 좌표 확인, 1회 재시도, 실패 기록 |

### 남은 항목의 재판정

| 이벤트 | 다시 보는 항목 |
|---|---|
| Space 전환·Mission Control 닫힘 | 방문 대기·이동 안내 |
| 잠금 해제 확인 | 잠금 보류 |
| 사용자 「남은 창 복원」 | 방문 대기·이동 안내·확인 필요·잠금 보류 전부 (사용자 요청으로 취급) |

완료한 창은 어느 재판정에서도 다시 옮기지 않는다. 취소 규칙은 F-02.6이다.

---

## C · 저장 층

수집은 복원과 같은 `DesktopObservation`을 쓰되 복원 실행 구간과 화면 안정화 전에는 돌지 않는다.

```
수집 트리거 (창 이동 정착 · 앱 전환 · 앱 종료 · Space 이벤트 뒤)
  → 전체 표준 창 + Space snapshot 한 번 읽기
  → 창 연결 갱신 · 사라진 창의 닫힌 환경 기록 (자동 저장과 무관)
  → 자동 저장 ON이면 저장 대기 이력 갱신 (복원 착지 위치는 제외)
작업 환경 이탈 · 정상 종료
  → 이력이 마지막 저장본과 다르면 저장 완료
```

---

## D · 앱 층

`WindowGateway`가 AX로 하는 일은 창 열거(제목·창 ID 포함), 이동·최소화 해제와 실제 좌표 재판독, 앱 실행·기본 창 열기·메뉴의 새 창 항목 누르기, 창 앞으로 가져오기뿐이다. 앱 실행은 실험실 부모 옵션이 켜졌을 때만 일어난다.

---

## 층 요약

| 층 | 소유 모듈 | 결정 |
|---|---|---|
| A | DisplayWatcher · ActiveSpaceWatcher · MissionControlWatcher · CollectTrigger | 언제 새 요청을 시작하고, 언제 남은 항목을 다시 볼지 |
| B | PlugbackController · RestoreSession · RestoreEngine · WindowMatching · DesktopObservation | 어떤 소스와 관찰을 쓰고, 저장 창마다 무엇을 할지 |
| C | WorkspaceLibrary · CaptureEngine | 무엇을 이력으로 모으고 언제 저장본이 되는지 |
| D | WindowGateway | 어느 창을 어떻게 옮기고 성공을 어떻게 검증할지 |
