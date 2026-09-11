import CoreGraphics
import Foundation

/// 직접 지정 OFF의 자동 배정 (D3). 확인된 연결을 먼저 고정한 뒤 남은 저장 자리와 후보 창을
/// 전체 이동 거리가 가장 짧은 일대일로 배정한다. 동률이면 크기 차이가 작은 쪽, 그래도 같으면 일정한 순서다.
/// 추정 배정이며 원래 창을 식별한 것이 아니다. 후보가 더 많으면 필요한 수만 고르고 나머지 창은 유지한다.
enum WindowMatching {
    struct Slot: Equatable {
        let id: UUID
        let target: CGRect
    }

    struct Candidate: Equatable {
        let index: Int
        let frame: CGRect
    }

    /// slot id → 후보 index. 입력 순서가 곧 동률의 일정한 순서다 — 호출자가 안정된 순서로 정렬해 넘긴다.
    static func assign(slots: [Slot], candidates: [Candidate]) -> [UUID: Int] {
        guard !slots.isEmpty, !candidates.isEmpty else { return [:] }
        let count = min(slots.count, candidates.count)
        // ponytail: 창 7개 이하면 전수 탐색(≤5040 경우), 그 이상은 탐욕 배정. 실사용 앱의 창 수에서는 전수가 항상 돈다.
        if slots.count <= 7 && candidates.count <= 7 {
            return exhaustive(slots: slots, candidates: candidates, count: count)
        }
        return greedy(slots: slots, candidates: candidates)
    }

    private struct Cost: Comparable {
        var distance: CGFloat
        var sizeDifference: CGFloat
        static func < (a: Cost, b: Cost) -> Bool {
            a.distance != b.distance ? a.distance < b.distance : a.sizeDifference < b.sizeDifference
        }
        static func + (a: Cost, b: Cost) -> Cost {
            Cost(distance: a.distance + b.distance, sizeDifference: a.sizeDifference + b.sizeDifference)
        }
    }

    private static func cost(_ slot: Slot, _ candidate: Candidate) -> Cost {
        let dx = slot.target.midX - candidate.frame.midX
        let dy = slot.target.midY - candidate.frame.midY
        return Cost(distance: (dx * dx + dy * dy).squareRoot(),
                    sizeDifference: abs(slot.target.width - candidate.frame.width)
                        + abs(slot.target.height - candidate.frame.height))
    }

    private static func exhaustive(slots: [Slot], candidates: [Candidate], count: Int) -> [UUID: Int] {
        var best: [Int] = []           // slot position → candidate array position (-1 = 미배정)
        var bestCost = Cost(distance: .infinity, sizeDifference: .infinity)
        var current = [Int](repeating: -1, count: slots.count)
        var used = [Bool](repeating: false, count: candidates.count)

        func search(_ position: Int, _ assigned: Int, _ running: Cost) {
            if running > bestCost { return }
            let remainingSlots = slots.count - position
            if assigned + remainingSlots < count { return }
            if position == slots.count {
                if assigned == count, running < bestCost { bestCost = running; best = current }
                return
            }
            for c in candidates.indices where !used[c] {
                used[c] = true
                current[position] = c
                search(position + 1, assigned + 1, running + cost(slots[position], candidates[c]))
                current[position] = -1
                used[c] = false
            }
            // 이 자리를 비워 두는 선택 — 후보보다 자리가 많을 때만 필요하다. 후보를 다 쓰는 배정이 항상 먼저 시도된다.
            if assigned + remainingSlots - 1 >= count {
                search(position + 1, assigned, running)
            }
        }
        search(0, 0, Cost(distance: 0, sizeDifference: 0))
        var out: [UUID: Int] = [:]
        for (position, c) in best.enumerated() where c >= 0 {
            out[slots[position].id] = candidates[c].index
        }
        return out
    }

    private static func greedy(slots: [Slot], candidates: [Candidate]) -> [UUID: Int] {
        var pairs: [(Cost, Int, Int)] = []
        for (s, slot) in slots.enumerated() {
            for (c, candidate) in candidates.enumerated() {
                pairs.append((cost(slot, candidate), s, c))
            }
        }
        pairs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1, $0.2) < ($1.1, $1.2) }
        var usedSlots = Set<Int>(), usedCandidates = Set<Int>()
        var out: [UUID: Int] = [:]
        for (_, s, c) in pairs where !usedSlots.contains(s) && !usedCandidates.contains(c) {
            usedSlots.insert(s); usedCandidates.insert(c)
            out[slots[s].id] = candidates[c].index
        }
        return out
    }
}
