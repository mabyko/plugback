import Foundation
import PlugbackKit

// 화면 식별자 실기기 스파이크용 프로브 (ARCHITECTURE M3).
// 스파이크 절차: 아래 상황 전후로 `swift run screen-probe`를 실행해 UUID가 유지되는지 비교한다.
//   ① 포트 변경(통과, 2026-08-16) ② 동일 모델 2대 동시 연결·순서 교체 재연결
//   ③ 재부팅 ④ 클램셸 진입/해제 ⑤ DisplayLink 독(보유 시)
// 배포 코드와 같은 SystemScreenProvider를 그대로 쓴다 — 프로브가 다른 것을 재면
// (원시 CGGetOnlineDisplayList, 미러링 정규화 누락) 측정이 스파이크 질문에 답하지 못한다.

let screens = SystemScreenProvider().screens()
print("식별된 화면 \(screens.count)대 · \(Date())  (식별 실패 화면은 목록에 없음 — F-01.4)")
for screen in screens {
    let fp = screen.fingerprint.map { "vendor \($0.vendor) · model \($0.model) · serial \($0.serial)" } ?? "없음"
    print("""

    \(screen.name) \(screen.isBuiltin ? "(내장)" : "(외장)")
      화면 식별자  \(screen.id)
      지문        \(fp)
      frame       \(Int(screen.frame.width))×\(Int(screen.frame.height)) @ (\(Int(screen.frame.minX)), \(Int(screen.frame.minY)))
    """)
}
