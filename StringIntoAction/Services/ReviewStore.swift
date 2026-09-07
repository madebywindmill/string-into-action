import Foundation

struct ApprovalRecord: Codable, Sendable {
    let fingerprint: String
    let approvedAt: Date
}

struct IgnoreRecord: Codable, Sendable {
    let ignoredAt: Date
}

struct ProjectReviewData: Codable, Sendable {
    var approvals: [String: ApprovalRecord] = [:]
    var ignores: [String: IgnoreRecord] = [:]
    var schemaVersion: Int = 2
    var snapshots: [OccurrenceSnapshot] = []

    enum CodingKeys: String, CodingKey { case approvals, ignores, schemaVersion, snapshots }

    init(approvals: [String: ApprovalRecord] = [:], ignores: [String: IgnoreRecord] = [:],
         schemaVersion: Int = 2, snapshots: [OccurrenceSnapshot] = []) {
        self.approvals = approvals
        self.ignores = ignores
        self.schemaVersion = schemaVersion
        self.snapshots = snapshots
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvals = try container.decode([String: ApprovalRecord].self, forKey: .approvals)
        ignores = try container.decode([String: IgnoreRecord].self, forKey: .ignores)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...2).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported review file version")
        }
        snapshots = schemaVersion == 2 ? try container.decode([OccurrenceSnapshot].self, forKey: .snapshots) : []
        guard Set(snapshots.map(\.id)).count == snapshots.count else {
            throw DecodingError.dataCorruptedError(forKey: .snapshots, in: container, debugDescription: "Duplicate string identities")
        }
    }
}

struct ReviewStore: Sendable {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appending(path: "StringIntoAction/Reviews", directoryHint: .isDirectory)
        }
    }

    func load(projectURL: URL) throws -> ProjectReviewData {
        let url = recordsURL(for: projectURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return ProjectReviewData()
        }
        if let records = try? decoder.decode(ProjectReviewData.self, from: data) {
            return records
        }
        // Version 1 stored the approval dictionary at the top level.
        if let legacy = try? decoder.decode([String: ApprovalRecord].self, from: data) {
            return ProjectReviewData(approvals: legacy, schemaVersion: 1)
        }
        // Never silently overwrite an unreadable or corrupt review database.
        return try decoder.decode(ProjectReviewData.self, from: data)
    }

    func save(_ records: ProjectReviewData, projectURL: URL) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = recordsURL(for: projectURL)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try load(projectURL: projectURL)
            if existing.schemaVersion < 2 {
                let backup = url.appendingPathExtension("v1-backup")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: url, to: backup)
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: recordsURL(for: projectURL), options: .atomic)
    }

    private func recordsURL(for projectURL: URL) -> URL {
        rootURL.appending(path: Hashing.sha256(projectURL.standardizedFileURL.path) + ".json")
    }
}
