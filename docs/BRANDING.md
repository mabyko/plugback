# 브랜딩 (Branding)

## Plugback

> 이름·카피·아이콘·톤의 기준 문서. 용어는 [CONTEXT.md](../CONTEXT.md)를 따른다.

---

## 1. 이름

| 항목 | 값 |
|---|---|
| 제품명 | **Plugback** |
| 워드마크 | `plugback` — 전부 소문자, 한 단어 |
| 한글 표기 | 플러그백 |
| 금지 표기 | ~~PlugBack~~ (CamelCase), ~~Plug Back~~ (두 단어), ~~플러그 백~~ |

CamelCase를 금지하는 이유: 1990~2000년대 Windows 유틸리티(FastBack, GoBack, RollBack Rx)의 톤이
대문자 B에서 온다. 소문자 한 단어 표기는 현대 Mac 생태계(Raycast, Loopback)의 문법이다.

## 2. 핵심 원칙: 브랜드 = 비침해성

이 제품의 정체성은 "조용함"이다 — 자동 저장 안 함, 분리 시 무동작, 권한 하나만, 폴링 없음, 확인창 없음.

**브랜드가 파는 것은 기능(옮긴다)이 아니라 절제(그것만 옮긴다)다.**
전체 스냅샷 방식 경쟁 제품과의 차별점 전부가 여기에 있다. 모든 카피는 이 원칙에서 나온다.

## 3. 카피

```
EN  Plugback
    Plug in. Your apps come back. Nothing else moves.

KR  플러그백
    꽂으면, 제자리로. 다른 창은 건드리지 않습니다.
```

* 랜딩 히어로는 세 문장을 세 줄로. 마지막 줄이 존재 이유다 — 빼지 않는다.
* 한 줄만 허용되는 곳(부제 등): EN `Restore your windows when you dock` / KR `꽂으면, 제자리로`
* 보조 카피 후보 (macOS 기본 동작과의 차별점, 2026-08-16 관찰 기반):
  EN `macOS remembers your last screen. Plugback remembers every screen.`
  KR `macOS는 마지막 화면만 기억합니다. Plugback은 모든 화면을 기억합니다.`

## 4. 아이콘

* **개념 1개만.** 플러그 + 화살표처럼 개념 2개를 합치면 16pt에서 뭉갠다.
* **메뉴바 글리프**: 모니터 외곽선 안에 작은 사각형 하나가 우측에 안착한 형태. 단색 템플릿 이미지.
  복원 순간 1회 펄스 외에는 움직이지 않는다.
* **앱 아이콘**: 같은 모티프에 스탠드(목+받침)를 더해 외장 모니터임을 밝힌다 — 스탠드는 모니터의 일부이므로 개념 추가가 아니다. 창은 우측 베젤에 닿아 안착. 악센트는 전기 앰버 1색. (2026-08-16 확정, 원본 assets/appicon.svg)
* 이름이 직설이므로 아이콘까지 플러그일 필요 없다. 아이콘은 결과(안착)를 그린다.

## 5. UI 언어

* UI 문구는 [CONTEXT.md](../CONTEXT.md) 용어 그대로. **은유 금지.**
* 마케팅 카피에서도 항해·정박류 은유를 쓰지 않는다. Plugback은 직설 이름이고, 톤은 하나로 유지한다.

## 6. 유통

Developer ID 배포(App Store 없음)이므로 **웹사이트가 유일한 유통 채널**이다.

- [ ] `plugback.app` 도메인 등록
- [ ] `@plugbackapp` (X)
- [ ] GitHub 조직 또는 레포명 `plugback`

## 7. 결정 기록

**5라운드 검증 요약** (2026-08): 직관성·문화권 교차·YC/실리콘밸리 관점 평가를 거침.

| 후보 | 결과 | 사유 |
|---|---|---|
| **Plugback** | ✅ 확정 | 검색 청정(동명 소프트웨어 없음). 트리거→결과 인과가 이름에 있음. 한글 무손실 |
| Homeport | ❌ 최종 탈락 | App Store에 동명 앱 2개. **Garmin HomePort**(해양 GPS Mac 소프트웨어)가 검색 점유 + 상표 리스크 |
| DisplayAnchor | ❌ | "Display"가 화면 정렬 앱으로 오분류시킴 |
| DockBack | ❌ | 한국어 "독백(혼잣말)" + 영어 "dock pay(감봉)" 이중 사망 |
| DockRecall, ExtRecall | ❌ | "리콜" = 제품 결함 회수. Windows Recall 오염 |
| AppReDock | ❌ | CamelCase 파싱 실패(Ap-pre-dock). macOS에서 Dock은 하단 바 |
| Snap 계열 전체 | ❌ | Snap = 창 분할기의 카테고리 워드. 우리의 유일한 포지셔닝("분할기가 아니다")을 자기부정 |

이 표의 결론은 재론하지 않는다. 새 정보(상표 분쟁, 도메인 확보 실패)가 생겼을 때만 다시 연다.
