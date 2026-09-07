import Foundation

struct OccurrenceSnapshot: Codable, Sendable {
    var id: String
    let relativePath: String
    let line: Int
    let column: Int
    var fingerprint: String
    let sourceFingerprint: String
    let structure: String
    let neighborhood: String
    let role: String

    init(_ occurrence: StringOccurrence) {
        id = occurrence.id
        relativePath = occurrence.relativePath
        line = occurrence.line
        column = occurrence.column
        fingerprint = Hashing.sha256(occurrence.rawValue)
        sourceFingerprint = occurrence.sourceFingerprint
        structure = occurrence.structureFingerprint
        neighborhood = occurrence.neighborhoodFingerprint
        role = occurrence.role.rawValue
    }
}

struct OccurrenceMatcher {
    struct Result {
        var occurrences: [StringOccurrence]
        var approvals: [String: ApprovalRecord]
        var ignores: [String: IgnoreRecord]
    }

    func reconcile(_ scanned: [StringOccurrence], with previous: ProjectReviewData) -> Result {
        let current = scanned.map(OccurrenceSnapshot.init)
        var assigned: [Int: Int] = [:]
        var used: Set<Int> = []

        // Count candidates against the FULL snapshots, not just the leftovers:
        // removing easy matches must never make an ambiguous match look unique.
        func matchUnique(key: (OccurrenceSnapshot) -> [String]?) {
            var oldGroups: [[String]: [Int]] = [:]
            var newGroups: [[String]: [Int]] = [:]
            for (index, snapshot) in previous.snapshots.enumerated() {
                if let value = key(snapshot) { oldGroups[value, default: []].append(index) }
            }
            for (index, snapshot) in current.enumerated() {
                if let value = key(snapshot) { newGroups[value, default: []].append(index) }
            }
            for (value, indices) in newGroups where indices.count == 1 {
                guard let old = oldGroups[value], old.count == 1,
                      assigned[indices[0]] == nil, !used.contains(old[0]) else { continue }
                assigned[indices[0]] = old[0]
                used.insert(old[0])
            }
        }

        matchUnique { [$0.relativePath, $0.sourceFingerprint, String($0.line), String($0.column), $0.fingerprint, $0.role] }
        matchUnique {
            guard !$0.structure.isEmpty else { return nil }
            return [$0.relativePath, $0.structure, $0.fingerprint]
        }
        // Repeated literals require distinct surrounding code as well as stable
        // multiplicity. Adding/removing duplicates deliberately requires review.
        let oldCounts = Dictionary(grouping: previous.snapshots) { [$0.relativePath, $0.structure, $0.fingerprint] }.mapValues(\.count)
        let newCounts = Dictionary(grouping: current) { [$0.relativePath, $0.structure, $0.fingerprint] }.mapValues(\.count)
        matchUnique {
            let group = [$0.relativePath, $0.structure, $0.fingerprint]
            guard !$0.structure.isEmpty, !$0.neighborhood.isEmpty,
                  oldCounts[group] == newCounts[group] else { return nil }
            return group + [$0.neighborhood]
        }
        // A unique structural match keeps identity even when content changes.
        // The original approval fingerprint then reports Changed, never Approved.
        matchUnique {
            guard !$0.structure.isEmpty else { return nil }
            return [$0.relativePath, $0.structure]
        }

        var result = Result(occurrences: scanned, approvals: previous.approvals, ignores: previous.ignores)
        for index in result.occurrences.indices {
            let id = assigned[index].map { previous.snapshots[$0].id } ?? UUID().uuidString
            result.occurrences[index].id = id
            if let oldIndex = assigned[index] {
                let old = previous.snapshots[oldIndex]
                // Ignore has no content fingerprint of its own. A changed literal
                // must not inherit a decision to hide its previous contents.
                if old.fingerprint != current[index].fingerprint {
                    result.ignores.removeValue(forKey: result.occurrences[index].ignoreID)
                }
            }
        }

        if previous.schemaVersion == 1 {
            // Legacy files lack context. Migrate only exact-location, exact-content
            // approvals that are unique in both the old records and the new file.
            let currentCounts = Dictionary(grouping: current) { [$0.relativePath, $0.fingerprint] }.mapValues(\.count)
            var legacyCounts: [[String]: Int] = [:]
            for (location, approval) in previous.approvals {
                let parts = location.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { continue }
                legacyCounts[[parts.dropLast(2).joined(separator: ":"), approval.fingerprint], default: 0] += 1
            }
            for (index, snapshot) in current.enumerated() {
                let key = [snapshot.relativePath, snapshot.fingerprint]
                let location = "\(snapshot.relativePath):\(snapshot.line):\(snapshot.column)"
                if currentCounts[key] == 1, legacyCounts[key] == 1,
                   let approval = previous.approvals[location], approval.fingerprint == snapshot.fingerprint {
                    result.approvals[result.occurrences[index].id] = approval
                }
            }
        }
        return result
    }
}
