import AppKit

/// 화면 열거 심. ScreenID(identity 추출·지문·미러링 정규화)는 실물 어댑터 안에 산다 —
/// 프로토콜 경계는 M3 이후에도 그대로 유지된다.
public protocol ScreenProvider {
    /// 지금 연결된 화면들. 식별에 실패한 화면은 목록에 없다 (F-01.4).
    func screens() -> [ScreenInfo]
}

/// 실물 어댑터 — NSScreen 열거 + 화면 식별자·지문 추출 + 미러링 정규화.
public final class SystemScreenProvider: ScreenProvider {
    public init() {}

    public func screens() -> [ScreenInfo] {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return [] }
        let primaryHeight = primary.frame.maxY

        var seen = Set<String>()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard screen.frame.width > 0, screen.frame.height > 0 else { return nil } // F-01.2 무효 해상도

            // 미러링 세트는 주 화면으로 정규화한 뒤 식별한다 — 부 화면에 별도 프로필이 생기면
            // 같은 창을 두 번 옮기게 된다 (F-01.6 위반). 0은 "자신이 주 화면"이라는 뜻.
            var effectiveID = displayID
            if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0 {
                let mirrorPrimary = CGDisplayMirrorsDisplay(displayID)
                if mirrorPrimary != 0 { effectiveID = mirrorPrimary }
            }

            // 화면 식별자: WindowServer가 배치 기억에 쓰는 그 UUID (2026-08 조사).
            // 실패한 화면은 목록에서 제외한다 — 잘못된 프로필보다 무동작이 낫다 (F-01.4).
            guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(effectiveID)?.takeRetainedValue()
            else { return nil }
            let uuid = CFUUIDCreateString(nil, uuidRef) as String
            guard seen.insert(uuid).inserted else { return nil } // SW 미러링: 부 화면 중복 제거

            // 지문은 키가 아니라 검증용 — UUID 배정이 뒤바뀌는 유일한 알려진 실패 모드를
            // 오작동이 아니라 무작동으로 바꾼다 (ARCHITECTURE ScreenID).
            let fingerprint = ScreenFingerprint(vendor: CGDisplayVendorNumber(effectiveID),
                                                model: CGDisplayModelNumber(effectiveID),
                                                serial: CGDisplaySerialNumber(effectiveID))

            // 좌상단 원점 통일 좌표계로 변환
            let f = screen.frame
            let flipped = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            return ScreenInfo(id: uuid, name: screen.localizedName, frame: flipped,
                              isBuiltin: CGDisplayIsBuiltin(effectiveID) != 0,
                              fingerprint: fingerprint)
        }
    }
}
