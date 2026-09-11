# 유저스토리 (User Stories)

Plugback의 사용자 관점 시나리오 카드.

## 사용자 (Persona)

**도킹 사용자** — 맥북 하나로 집과 회사를 오가며, 양쪽에서 서로 다른 외장 화면에 연결해 일한다.
이동 중에는 내장 화면만으로 작업한다. 창 배치에 신경을 쓰는 편이고, 매번 다시 맞추는 것을 번거로워한다.

## 목록

| ID | 제목 | 우선순위 |
|---|---|---|
| [US-001](./US-001-auto-restore-on-connect.md) | 외장 화면을 연결하면 창이 제자리로 돌아온다 | P0 |
| [US-002](./US-002-save-layout.md) | 지금 배치를 이 작업 환경의 저장본으로 저장한다 | P0 |
| [US-003](./US-003-per-screen-profile.md) | 집과 회사가 서로 다른 저장본을 갖는다 | P0 |
| [US-004](./US-004-skip-closed-apps.md) | 꺼둔 앱이 멋대로 켜지지 않는다 | P0 |
| [US-005](./US-005-protect-builtin-screen.md) | 내장 화면에서 하던 작업이 흐트러지지 않는다 | P0 |
| [US-006](./US-006-manage-target-apps.md) | 어떤 앱을 복원할지 고른다 | P1 |
| [US-007](./US-007-manual-restore.md) | 원할 때 직접 복원한다 | P1 |
| [US-008](./US-008-restore-result.md) | 왜 안 옮겨졌는지 확인한다 | P1 |
| [US-009](./US-009-sleep-and-clamshell.md) | 덮개를 여닫아도 창이 튀지 않는다 | P0 |
| [US-010](./US-010-permission-onboarding.md) | 처음 켰을 때 무엇을 해야 하는지 안다 | P1 |
| [US-011](./US-011-launch-at-login.md) | 켜두면 알아서 돌아간다 | P2 |
| [US-012](./US-012-manage-saved-profiles.md) | 저장된 작업 환경을 한눈에 관리한다 | P2 |
| [US-013](./US-013-lab-auto-slot.md) | 저장을 잊어도 어제 배치로 돌아온다 (자동 저장) | P1 |

## 카드 형식

각 카드는 스토리 한 줄, 인수 조건(Given/When/Then), 관련 문서 링크로 구성한다.
인수 조건은 **관찰 가능한 결과**로만 쓴다. API나 상수는 [FUNCTIONAL_SPEC.md](../FUNCTIONAL_SPEC.md)에 있다.
