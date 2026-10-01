import Foundation

enum ReciprocalRankFusion {
    static let defaultK = 60

    static func fuse<ID: Hashable>(rankings: [[ID]], k: Int = defaultK) -> [ID] {
        var scores: [ID: Double] = [:]
        var order: [ID] = []
        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                scores[id, default: 0] += 1 / Double(k + index + 1)
                if !order.contains(id) { order.append(id) }
            }
        }
        return order.sorted { lhs, rhs in
            let left = scores[lhs] ?? 0
            let right = scores[rhs] ?? 0
            if left == right { return false }
            return left > right
        }
    }
}
