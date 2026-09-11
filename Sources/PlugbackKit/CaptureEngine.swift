import CoreGraphics
import Foundation

/// 저장·수집 엔진 (F-03). 거의 순수 함수 — 한 번의 관찰(창 목록 + Space snapshot)을 작업 환경 기록으로 바꾼다.
/// 창 하나가 창 위치 기록 하나다(D1). 같은 실제 창의 이동과 새 창 추가는 실행 중 연결(placement ↔ windowServerID)로 구별한다.
/// 관찰하지 못한 기존 기록은 보존하고, 같은 환경에서 닫힌 것으로 확인한 기록과 내장 화면으로 옮긴 창의 기록만 뺀다(D4·D9).
public enum CaptureEngine {
    struct Observation: Equatable {
        var placements: [WindowPlacement]
        var screens: [ScreenRecord]
        /// 이번 관찰에서 실제 창과 연결된 저장 자리. 갱신된 기존 자리와 새 자리 모두 포함한다.
        var links: [UUID: CGWindowID]
        /// 외장 화면에서 표준 창을 확인한 앱 — 제외하지 않았다면 기본 포함 대상이다 (D4).
        var observedApps: [String: String]
        /// 연결된 창이 내장 화면으로 옮겨진 것을 확인한 기존 자리 — 새 이력에서 뺀다 (D4).
        var droppedPlacementIDs: Set<UUID>
        /// 이번에 현재 Space로 확인한 화면별 일반 Space 이름 (관찰 범위 표시용).
        var observedSpaceNames: [String: Set<String>]
    }

    /// - windows: 한 열거의 표준 창 전부. 숨김·최소화·전체화면(불명 포함)은 기록하지 않는다 (F-03.2).
    /// - screens: 작업 환경의 외장 화면들. 내장·다른 화면에 있는 창은 기록하지 않는다.
    /// - base: 보존할 기존 기록 (마지막 저장본 또는 저장 대기 이력).
    /// - links: 기존 저장 자리 ↔ 실행 중 창의 유효한 연결.
    /// - droppable: 이 환경에서 외장 화면에 있는 것을 확인한 적 있는 연결 자리 — 내장에서 발견되면 사용자가 옮긴 것이다.
    ///   화면 구성 변경으로 macOS가 내장에 모은 창은 여기 없으므로 기록을 보존한다 (W17·S17).
    static func observe(
        windows: [WindowInfo],
        screens: [ScreenInfo],
        snapshot: SpaceSnapshot?,
        base: WorkspaceSnapshot?,
        links: [UUID: CGWindowID],
        excludedBundleIDs: Set<String>,
        closedPlacementIDs: Set<UUID>,
        droppable: Set<UUID>? = nil
    ) -> Observation {
        let droppable = droppable ?? Set(links.keys)
        let externals = screens.filter { !$0.isBuiltin && $0.frame.width > 0 && $0.frame.height > 0 }
        let placementByWindow: [CGWindowID: UUID] = Dictionary(
            links.compactMap { id, wsid in base?.placements.contains { $0.id == id } == true ? (wsid, id) : nil },
            uniquingKeysWith: { first, _ in first }
        )
        var updated: [UUID: WindowPlacement] = [:]
        var appended: [WindowPlacement] = []
        var newLinks: [UUID: CGWindowID] = [:]
        var observedApps: [String: String] = [:]
        var dropped: Set<UUID> = []
        var observedSpaces: [String: Set<String>] = [:]

        for window in windows where !window.isHidden && !window.isMinimized
            && window.fullscreenState == .windowed {
            // 제외한 앱의 기록은 건드리지 않는다 — 다시 켜면 저장돼 있던 자리로 돌아온다 (US-006 AC-2).
            guard !excludedBundleIDs.contains(window.appBundleID) else { continue }
            let linked = window.windowServerID.flatMap { placementByWindow[$0] }
            guard let screen = externals.first(where: { $0.contains(window) }) else {
                // 연결을 유지한 채 외장 창을 내장·작업 환경 밖으로 옮겼다 — 저장 완료 뒤부터 외장 복원 대상에서 뺀다 (D4).
                if let linked, droppable.contains(linked) { dropped.insert(linked) }
                continue
            }

            var hint: SpaceHint?
            if let snapshot {
                switch SpacePlacement.of(windowServerIDs: [window.windowServerID], on: screen.id, in: snapshot) {
                case .current(let found):
                    guard let identity = found.identity else { continue }
                    hint = identity
                    observedSpaces[screen.id, default: []].insert(identity.opaqueName)
                default:
                    // 비활성 Space·잔류·판정 불가는 이번에 확인한 것이 아니다 — 기존 기록을 유지한다 (S01·S04).
                    continue
                }
            }
            observedApps[window.appBundleID] = window.appName
            let rect = UnitRect(window.frame, in: screen.frame)
            if let linked, let existing = base?.placements.first(where: { $0.id == linked }) {
                var next = existing
                next.displayName = window.appName
                next.screenID = screen.id
                next.space = hint
                // 허용 오차 안의 차이는 좌표를 갱신하지 않는다 (드리프트 방지, F-08.4).
                let sameSpot = existing.screenID == screen.id && existing.space == hint
                    && RestoreEngine.approximatelyEqual(existing.unitRect.frame(in: screen.frame), window.frame)
                if !sameSpot { next.unitRect = rect }
                updated[linked] = next
                if let wsid = window.windowServerID { newLinks[linked] = wsid }
            } else {
                let placement = WindowPlacement(bundleID: window.appBundleID, displayName: window.appName,
                                                screenID: screen.id, space: hint, unitRect: rect)
                appended.append(placement)
                if let wsid = window.windowServerID { newLinks[placement.id] = wsid }
            }
        }

        var placements: [WindowPlacement] = []
        for existing in base?.placements ?? [] {
            if let next = updated[existing.id] {
                placements.append(next)
            } else if dropped.contains(existing.id) || closedPlacementIDs.contains(existing.id) {
                continue
            } else {
                placements.append(existing) // 관찰하지 못한 기록은 보존한다 (S04)
            }
        }
        placements.append(contentsOf: appended)

        let screenRecords = externals.map { screen -> ScreenRecord in
            var record = base?.screen(screen.id)
                ?? ScreenRecord(id: screen.id, name: screen.name)
            record.name = screen.name
            record.fingerprint = screen.fingerprint
            record.portLocation = screen.portLocation
            if let snapshot, let display = snapshot.onlyDisplay(screen.id) {
                record.regularSpaces = display.spaces.compactMap { space in
                    SpacePlacement.of(space.runtimeID, on: screen.id, in: snapshot).onTarget?.identity
                }
            }
            return record
        }

        return Observation(placements: placements, screens: screenRecords, links: newLinks,
                           observedApps: observedApps, droppedPlacementIDs: dropped,
                           observedSpaceNames: observedSpaces)
    }
}
