import AppKit
import IOKit

/// 화면 열거 심. ScreenID(identity 추출·지문·미러링 정규화)는 실물 어댑터 안에 산다 —
/// 프로토콜 경계는 M3 이후에도 그대로 유지된다.
public protocol ScreenProvider {
    /// 지금 연결된 화면들. 식별에 실패한 화면은 목록에 없다 (F-01.4).
    func screens() -> [ScreenInfo]
}

/// 실물 어댑터 — NSScreen 열거 + 화면 식별자·지문 추출 + 미러링 정규화 + 포트 위치 조회.
public final class SystemScreenProvider: ScreenProvider {
    public init() {}

    public func screens() -> [ScreenInfo] {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return [] }
        let primaryHeight = primary.frame.maxY
        let ports = PortLocator.locations()

        var seen = Set<String>()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard screen.frame.width > 0, screen.frame.height > 0 else { return nil } // F-01.2 무효 해상도

            // 미러링 세트는 주 화면으로 정규화한 뒤 식별한다 — 부 화면에 별도 기록이 생기면
            // 같은 창을 두 번 옮기게 된다 (F-01.6 위반). 0은 "자신이 주 화면"이라는 뜻.
            var effectiveID = displayID
            if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0 {
                let mirrorPrimary = CGDisplayMirrorsDisplay(displayID)
                if mirrorPrimary != 0 { effectiveID = mirrorPrimary }
            }

            // 화면 식별자: WindowServer가 배치 기억에 쓰는 그 UUID (2026-08 조사).
            guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(effectiveID)?.takeRetainedValue()
            else { return nil }
            let uuid = CFUUIDCreateString(nil, uuidRef) as String
            guard seen.insert(uuid).inserted else { return nil } // SW 미러링: 부 화면 중복 제거

            // 지문은 키가 아니라 검증용 — UUID 배정이 뒤바뀌는 유일한 알려진 실패 모드를
            // 오작동이 아니라 무작동으로 바꾼다 (ARCHITECTURE ScreenID).
            let fingerprint = ScreenFingerprint(vendor: CGDisplayVendorNumber(effectiveID),
                                                model: CGDisplayModelNumber(effectiveID),
                                                serial: CGDisplaySerialNumber(effectiveID))

            let f = screen.frame
            let flipped = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            let isBuiltin = CGDisplayIsBuiltin(effectiveID) != 0
            return ScreenInfo(id: uuid, name: screen.localizedName, frame: flipped,
                              isBuiltin: isBuiltin,
                              fingerprint: fingerprint,
                              portLocation: isBuiltin ? nil : ports[fingerprint])
        }
    }
}

/// 포트 위치 조회 (P20 표시용). IORegistry를 읽기만 한다 — 2026-09-11 M2 Max·LG HDR 4K 한 대에서 확인한 구조:
/// `IOPortTransportStateDisplayPort`가 EDID와 `ParentBuiltInPortType/Number`를, DeviceTree의 `AppleHPMBusDevice`(hpmN)가
/// `port-type/port-number/port-location`을 갖는다. 화면 대응은 EDID의 제조사·제품·시리얼을 지문과 맞춰 한다.
/// 독·DisplayLink·다른 맥 모델은 미검증이며, 못 찾으면 nil이다 — 추정 위치를 표시하지 않는다.
enum PortLocator {
    static func locations() -> [ScreenFingerprint: PortLocation] {
        var byPort: [String: String] = [:] // "type/number" → location
        forEachService(matching: "AppleHPMBusDevice") { entry in
            guard let type = uint32Property(entry, "port-type"),
                  let number = uint32Property(entry, "port-number"),
                  let location = stringProperty(entry, "port-location") else { return }
            byPort["\(type)/\(number)"] = location
        }
        var out: [ScreenFingerprint: PortLocation] = [:]
        forEachService(matching: "IOPortTransportStateDisplayPort") { entry in
            guard let edid = dataProperty(entry, "EDID"), edid.count >= 16,
                  let type = numberProperty(entry, "ParentBuiltInPortType"),
                  let number = numberProperty(entry, "ParentBuiltInPortNumber"),
                  let location = byPort["\(type)/\(number)"] else { return }
            // EDID 바이트 8–9 제조사(빅엔디언), 10–11 제품(리틀엔디언), 12–15 시리얼(리틀엔디언) — CGDisplay*Number와 같은 값이다.
            let vendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
            let model = UInt32(edid[10]) | UInt32(edid[11]) << 8
            let serial = UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24
            let fingerprint = ScreenFingerprint(vendor: vendor, model: model, serial: serial)
            // 같은 지문이 두 포트에서 보이면 어느 쪽인지 확정할 수 없다 — 표시하지 않는다.
            if out[fingerprint] != nil { out[fingerprint] = .other("ambiguous") } else { out[fingerprint] = PortLocation(rawLocation: location) }
        }
        return out.filter { $0.value != .other("ambiguous") }
    }

    private static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func dataProperty(_ entry: io_registry_entry_t, _ key: String) -> Data? {
        property(entry, key) as? Data
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        if let string = property(entry, key) as? String { return string }
        guard let data = property(entry, key) as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private static func uint32Property(_ entry: io_registry_entry_t, _ key: String) -> UInt32? {
        if let number = property(entry, key) as? NSNumber { return number.uint32Value }
        guard let data = property(entry, key) as? Data, data.count >= 4 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    private static func numberProperty(_ entry: io_registry_entry_t, _ key: String) -> UInt32? {
        (property(entry, key) as? NSNumber)?.uint32Value
    }
}
