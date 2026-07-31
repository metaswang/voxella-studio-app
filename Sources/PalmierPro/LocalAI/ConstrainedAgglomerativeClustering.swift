import Foundation

struct ConstrainedClusterItem: Equatable, Sendable {
    let windowIndex: Int
    let localSpeakerID: Int
    let embedding: [Float]
}

struct ConstrainedClusteringResult: Equatable, Sendable {
    let assignments: [Int]
    let centroids: [[Float]]
    let performedMerges: Int
    let distanceEvaluations: Int
    let reachedTargetCount: Bool
}

/// Centroid-linkage AHC with a same-window cannot-link constraint.
///
/// Every initial legal distance is evaluated once. A merge only invalidates
/// pairs touching the receiving cluster, so only those distances are recomputed.
/// Stale heap entries are discarded by version instead of rebuilding or scanning
/// the full active-pair matrix on every iteration.
enum ConstrainedAgglomerativeClustering {
    private struct Cluster {
        var active = true
        var version = 0
        var centroid: [Float]
        var members: [Int]
        var windows: Set<Int>
    }

    private struct Pair: Comparable {
        let distance: Float
        let left: Int
        let right: Int
        let leftVersion: Int
        let rightVersion: Int

        static func < (lhs: Pair, rhs: Pair) -> Bool {
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.left != rhs.left { return lhs.left < rhs.left }
            return lhs.right < rhs.right
        }
    }

    private struct MinHeap<Element: Comparable> {
        var values: [Element] = []

        mutating func push(_ value: Element) {
            values.append(value)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard values[index] < values[parent] else { break }
                values.swapAt(index, parent)
                index = parent
            }
        }

        mutating func pop() -> Element? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let result = values[0]
            values[0] = values.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                let right = left + 1
                var smallest = index
                if left < values.count, values[left] < values[smallest] { smallest = left }
                if right < values.count, values[right] < values[smallest] { smallest = right }
                guard smallest != index else { break }
                values.swapAt(index, smallest)
                index = smallest
            }
            return result
        }
    }

    static func cluster(
        items: [ConstrainedClusterItem],
        threshold: Float,
        targetCount: Int? = nil,
        progress: @escaping @Sendable (_ completedMerges: Int, _ maximumMerges: Int) -> Void = { _, _ in }
    ) throws -> ConstrainedClusteringResult {
        guard !items.isEmpty else {
            return .init(
                assignments: [], centroids: [], performedMerges: 0,
                distanceEvaluations: 0, reachedTargetCount: targetCount == nil || targetCount == 0
            )
        }
        let dimension = items[0].embedding.count
        guard dimension > 0, items.allSatisfy({ $0.embedding.count == dimension }) else {
            throw CocoaError(.coderInvalidValue)
        }
        let target = targetCount.map { min(items.count, max(1, $0)) }
        var clusters = items.enumerated().map { index, item in
            Cluster(
                centroid: item.embedding,
                members: [index],
                windows: [item.windowIndex]
            )
        }
        var heap = MinHeap<Pair>()
        var distanceEvaluations = 0

        func pair(_ first: Int, _ second: Int) -> Pair? {
            let left = min(first, second)
            let right = max(first, second)
            guard clusters[left].active, clusters[right].active,
                  clusters[left].windows.isDisjoint(with: clusters[right].windows) else { return nil }
            return Pair(
                distance: cosineDistance(clusters[left].centroid, clusters[right].centroid),
                left: left,
                right: right,
                leftVersion: clusters[left].version,
                rightVersion: clusters[right].version
            )
        }

        if items.count > 1 {
            for left in 0..<(items.count - 1) {
                for right in (left + 1)..<items.count {
                    if let candidate = pair(left, right) {
                        heap.push(candidate)
                        distanceEvaluations += 1
                    }
                }
            }
        }

        var activeCount = items.count
        var performedMerges = 0
        let maximumMerges = items.count - (target ?? 1)
        progress(0, maximumMerges)

        while activeCount > (target ?? 1) {
            try Task.checkCancellation()
            var best: Pair?
            while let candidate = heap.pop() {
                guard clusters[candidate.left].active,
                      clusters[candidate.right].active,
                      clusters[candidate.left].version == candidate.leftVersion,
                      clusters[candidate.right].version == candidate.rightVersion,
                      clusters[candidate.left].windows.isDisjoint(with: clusters[candidate.right].windows) else {
                    continue
                }
                best = candidate
                break
            }
            guard let best else { break }
            if target == nil, best.distance >= threshold { break }

            let receiver = best.left
            let donor = best.right
            let receiverSize = Float(clusters[receiver].members.count)
            let donorSize = Float(clusters[donor].members.count)
            let totalSize = receiverSize + donorSize
            for component in 0..<dimension {
                clusters[receiver].centroid[component] = (
                    clusters[receiver].centroid[component] * receiverSize
                        + clusters[donor].centroid[component] * donorSize
                ) / totalSize
            }
            clusters[receiver].members.append(contentsOf: clusters[donor].members)
            clusters[receiver].windows.formUnion(clusters[donor].windows)
            clusters[receiver].version += 1
            clusters[donor].active = false
            clusters[donor].version += 1
            activeCount -= 1
            performedMerges += 1

            for other in clusters.indices where other != receiver && clusters[other].active {
                if let candidate = pair(receiver, other) {
                    heap.push(candidate)
                    distanceEvaluations += 1
                }
            }
            progress(performedMerges, maximumMerges)
        }

        let active = clusters.indices.filter { clusters[$0].active }.sorted()
        let compactID = Dictionary(uniqueKeysWithValues: active.enumerated().map { ($1, $0) })
        var assignments = [Int](repeating: 0, count: items.count)
        for clusterID in active {
            for member in clusters[clusterID].members {
                assignments[member] = compactID[clusterID]!
            }
        }
        return ConstrainedClusteringResult(
            assignments: assignments,
            centroids: active.map { clusters[$0].centroid },
            performedMerges: performedMerges,
            distanceEvaluations: distanceEvaluations,
            reachedTargetCount: target.map { active.count == $0 } ?? true
        )
    }

    private static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = (lhsNorm * rhsNorm).squareRoot()
        return denominator > 1e-10 ? 1 - dot / denominator : 2
    }
}
