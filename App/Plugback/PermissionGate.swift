import AppKit
import ApplicationServices

// 권한 게이트 — 얇은 유틸로 유지한다. 모듈로 키우지 않는다 (docs/ARCHITECTURE.md).
enum PermissionGate {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    // 사용자가 버튼을 눌렀을 때만 호출한다. 프롬프트 API로 앱을 손쉬운 사용 목록에 등록시키고
    // (이게 없으면 목록에 안 나타나 사용자가 + 버튼으로 직접 추가해야 한다), 설정 위치로 딥링크한다.
    // (US-010 AC-1: 해당 위치로 바로 갈 수 있다)
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
