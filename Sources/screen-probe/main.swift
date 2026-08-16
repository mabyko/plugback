import ApplicationServices
import CoreGraphics
import Foundation

// 화면 식별자 실기기 스파이크용 프로브 (ARCHITECTURE M3).
// 스파이크 절차: 아래 상황 전후로 `swift run screen-probe`를 실행해 UUID가 유지되는지 비교한다.
//   ① 포트 변경(최우선 — 깨지면 스킴 재설계) ② 동일 모델 2대 동시 연결·순서 교체 재연결
//   ③ 재부팅 ④ 클램셸 진입/해제 ⑤ DisplayLink 독(보유 시)

var count: UInt32 = 0
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
CGGetOnlineDisplayList(16, &ids, &count)

print("연결된 화면 \(count)대 · \(Date())")
for id in ids.prefix(Int(count)) {
    let uuid: String
    if let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
        uuid = CFUUIDCreateString(nil, ref) as String
    } else {
        uuid = "식별 실패 (F-01.4: 이 화면은 복원 대상에서 제외됨)"
    }
    let mirrorPrimary = CGDisplayMirrorsDisplay(id)
    let bounds = CGDisplayBounds(id)
    print("""

    displayID \(id) \(CGDisplayIsBuiltin(id) != 0 ? "(내장)" : "(외장)")
      UUID    \(uuid)
      지문    vendor \(CGDisplayVendorNumber(id)) · model \(CGDisplayModelNumber(id)) · serial \(CGDisplaySerialNumber(id))
      해상도  \(Int(bounds.width))×\(Int(bounds.height)) @ (\(Int(bounds.minX)), \(Int(bounds.minY)))\(mirrorPrimary != 0 ? " · 미러링(주 화면 displayID: \(mirrorPrimary))" : "")
    """)
}
