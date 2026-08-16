import AppKit

/// 화면 열거 심. M3의 ScreenID(identity 추출·지문 검증·미러링 정규화)는
/// 실물 어댑터 안에서 자란다 — 프로토콜 경계는 그대로 유지된다.
public protocol ScreenProvider {
    /// 지금 연결된 화면들. 식별에 실패한 화면은 목록에 없다 (F-01.4).
    func screens() -> [ScreenInfo]
}

/// 실물 어댑터 — NSScreen 열거 + 화면 식별자 추출.
public final class SystemScreenProvider: ScreenProvider {
    public init() {}

    public func screens() -> [ScreenInfo] {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return [] }
        let primaryHeight = primary.frame.maxY

        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard screen.frame.width > 0, screen.frame.height > 0 else { return nil } // F-01.2 무효 해상도

            // 화면 식별자: WindowServer가 배치 기억에 쓰는 그 UUID (2026-08 조사).
            // 실패한 화면은 목록에서 제외한다 — 잘못된 프로필보다 무동작이 낫다 (F-01.4).
            // ponytail: 미러링 정규화·지문 검증은 M3의 ScreenID 스파이크에서 여기로 들어온다.
            guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
            else { return nil }
            let uuid = CFUUIDCreateString(nil, uuidRef) as String

            // 좌상단 원점 통일 좌표계로 변환
            let f = screen.frame
            let flipped = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            return ScreenInfo(id: uuid, name: screen.localizedName, frame: flipped,
                              isBuiltin: CGDisplayIsBuiltin(displayID) != 0)
        }
    }
}
