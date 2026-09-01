# 자동·안내형 복원 흐름

## Plugback

이 문서는 외장 화면 연결이나 복원 버튼 한 번이 창 이동까지 이어지는 순서만 설명한다. 조건의 기준은 [FUNCTIONAL_SPEC.md](./FUNCTIONAL_SPEC.md), 용어는 [CONTEXT.md](../CONTEXT.md)를 따른다.

Plugback이 직접 바꾸는 것은 대상 앱의 표준 창 위치뿐이다. Space 화면 소속, Space 순서, native fullscreen 상태는 쓰지 않는다.

---

## A · 이벤트 층

복원을 새로 시작하는 입력은 둘뿐이다.

1. `DisplayWatcher`가 안정된 외장 화면 연결을 알리고 복원 모드가 자동이다.
2. 사용자가 카드 버튼이나 시스템 단축어로 수동 복원을 실행한다.

`ActiveSpaceWatcher`와 `MissionControlWatcher`는 새 복원을 만들지 않는다. 이미 시작한 안내형 복원이 있으면 그 상태만 다시 확인한다. 진행 중 안내가 없을 때는 자동 슬롯 수집 신호로 쓴다.

```
외장 화면 연결 ── DisplayWatcher ─┐
복원 버튼·단축어 ─────────────────┼─▶ PlugbackController.restoreNow
                                  │
Mission Control 닫힘 ─────────────┤
활성 Space 변화 ──────────────────┘  (진행 중 recovery만 recheck)
```

DisplayWatcher 안에서는 원시 화면 이벤트 압축, 유효 화면 판정, 잠자기·잠금 억제가 먼저 끝난다(F-01). 이 단계 전에는 프로필이나 창을 읽지 않는다.

---

## B · 정책·세션 층

컨트롤러는 화면과 복원 소스를 고르고, `RestoreSession`은 한 번 시작한 안내의 수명만 관리한다.

### 새 복원

```
PlugbackController
  ├─ 화면 목록·권한 동기화
  ├─ 화면별 최신 복원 소스 선택
  └─ RestoreSession.restore
       ├─ 이전 recovery 폐기
       ├─ DesktopObservation.drain
       ├─ 같은 회차의 (표준 창, stable Space snapshot) 한 번 읽기
       ├─ 시작 시 실제 잔류 Space만 recovery로 등록
       └─ RestoreEngine.restore
```

프로필에 Space overlay가 없으면 기존 선택 복원처럼 표준 창을 복원한다. binding이 있는데 snapshot이나 membership을 확실히 판정하지 못하면 평면 복원으로 내려가지 않고 그 앱을 건드리지 않는다.

저장된 일반 Space의 시작 상태별 동작은 다음과 같다.

| 시작 상태 | 동작 |
|---|---|
| 목적 화면의 현재 Space | 묶인 표준 창을 바로 복원 |
| 목적 화면의 비활성 Space | 건드리지 않음. 일반 방문 복원을 만들지 않음 |
| 다른 화면의 잔류 Space | 출발·목적 화면 안내를 가진 recovery 생성 |
| 없음·중복·불명·fullscreen | fail-closed. 창과 Space를 건드리지 않음 |

### 안내 이어가기

```
잔류 감지
  → 카드: "출발 화면 → 목적 화면 · Mission Control에서 옮겨 주세요"
  → 사용자가 Space를 한 번 이동
  → Mission Control 닫힘
  → RestoreSession.recheck
      ├─ 여전히 다른 화면: 이동 안내 유지
      ├─ 목적 화면의 비활성 Space: 방문 안내
      ├─ 목적 화면의 현재 Space: 해당 recovery의 창만 복원하고 완료
      └─ 판정 불가: 안내 불가 표시, 무동작
  → 사용자가 방문 안내된 Space를 한 번 엶
  → 활성 Space 이벤트
  → 같은 recheck가 창 위치를 복원하고 recovery 종료
```

대상 앱이 없는 저장 Space는 recovery를 만들지 않는다. 자동·수동 모드는 recovery를 시작하는 시점만 바꾸며, 시작된 recovery는 어느 모드에서도 이벤트에 따라 이어진다.

Space 이벤트 직후 첫 snapshot이 이전 상태일 수 있어 정착 간격 뒤 딱 한 번만 재확인한다. 주기 폴링이나 재시도 루프는 없다.

새 복원, 저장, 대상 앱 변경, 프로필 삭제, 복원 소스 변경은 기존 recovery를 폐기한다. 사용자가 새 배치를 선언했는데 옛 안내가 살아남지 않게 하기 위해서다.

---

## C · 화면 층

`RestoreEngine`은 화면 식별자 순서로 처리한다.

1. 저장 지문과 현재 지문이 다르면 화면 전체를 건너뛴다.
2. 같은 대상 앱이 여러 화면 프로필에 있으면 먼저 온 적격 화면이 한 번만 담당한다.
3. 일반 복원은 화면의 모든 담당 앱을, recovery 완료 복원은 그 recovery에 묶인 앱만 받는다.
4. 결과는 화면별 `RestoreResult`로 돌려준다.

Space 자체의 화면 소속이나 순서를 바꾸는 호출은 이 층에 없다.

---

## D · 앱 층

대상 앱 하나마다 다음 순서를 따른다.

```
실행 중인가?
  ├─ 아니오 → 건너뜀
  └─ 예
      → 같은 observation의 표준 창에서 안전한 한 창 선택
      → 전체화면이면 건너뜀
      → 최소화면 기본 건너뜀, 옵션이 켜졌으면 Dock에서 꺼냄
      → 이미 제자리면 건너뜀
      → 목표 비율 좌표로 이동
      → 실제 좌표 확인
          ├─ 허용 오차 안 → 이동 완료
          └─ 밖/응답 없음 → 1회 재시도 후 실패
```

꺼진 앱은 실행하지 않는다. 실행 중인데 창이 없는 legacy 대상만 옵션에 따라 새 창을 열 수 있다. Space binding이 있는 비활성·불명 대상에는 새 창을 만들지 않는다.

---

## 층 요약

| 층 | 소유 모듈 | 결정 |
|---|---|---|
| A | DisplayWatcher · ActiveSpaceWatcher · MissionControlWatcher | 언제 새 복원을 시작하고, 언제 기존 안내를 다시 볼지 |
| B | PlugbackController · RestoreSession · DesktopObservation | 어떤 복원 소스와 한 observation을 쓰고, recovery를 언제 끝낼지 |
| C | RestoreEngine | 어느 화면이 어느 앱을 한 번 담당할지 |
| D | RestoreEngine · WindowGateway | 어느 창을 건너뛰고 어디로 옮기며 성공을 어떻게 검증할지 |
