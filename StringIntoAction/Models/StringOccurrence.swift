import Foundation

struct StringOccurrence: Identifiable, Hashable, Sendable {
    enum Confidence: String, Hashable, Sendable {
        case review
        case possible
    }

    enum LiteralRole: String, Hashable, Sendable {
        case userInterface
        case localization
        case webContent
        case interfaceBuilder
        case message
        case unknown
    }

    enum Language: String, Sendable {
        case swift = "Swift"
        case objectiveC = "Objective-C"
        case strings = "Strings"
        case javascript = "JavaScript"
        case typescript = "TypeScript"
        case html = "HTML"
        case json = "JSON"
        case stringCatalog = "String Catalog"
        case interfaceBuilder = "Interface Builder"

        var symbol: String {
            switch self {
            case .swift: "swift"
            case .objectiveC: "curlybraces"
            case .strings, .stringCatalog: "character.book.closed"
            case .javascript, .typescript: "chevron.left.forwardslash.chevron.right"
            case .html, .interfaceBuilder: "globe"
            case .json: "list.bullet.rectangle"
            }
        }
    }

    enum LiteralStyle: Hashable, Sendable {
        case doubleQuoted
        case singleQuoted
        case template
        case htmlText
        case htmlAttribute

        var quoteCharacter: Character? {
            switch self {
            case .doubleQuoted: "\""
            case .singleQuoted: "'"
            case .template: "`"
            case .htmlText, .htmlAttribute: nil
            }
        }
    }

    var id: String
    let fileURL: URL
    let relativePath: String
    let line: Int
    let column: Int
    let value: String
    let rawValue: String
    let contextLines: [ContextLine]
    let contentRange: NSRange
    let sourceFingerprint: String
    let language: Language
    let style: LiteralStyle
    let isEditable: Bool
    let confidence: Confidence
    let detectionReason: String
    let role: LiteralRole
    var structureFingerprint: String = ""
    var neighborhoodFingerprint: String = ""

    var fileName: String { fileURL.lastPathComponent }
    var locationDescription: String { "\(relativePath):\(line)" }
    var summary: String {
        value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var ignoreID: String { "\(id):\(role.rawValue)" }
}

struct ContextLine: Identifiable, Hashable, Sendable {
    let number: Int
    let text: String
    let isSelected: Bool

    var id: Int { number }
}

enum ReviewState: Int, Comparable, Sendable {
    case changed
    case needsReview
    case approved
    case ignored

    static func < (lhs: ReviewState, rhs: ReviewState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .changed: "Changed"
        case .needsReview: "Needs Review"
        case .approved: "Approved"
        case .ignored: "Ignored"
        }
    }

    var symbol: String {
        switch self {
        case .changed: "arrow.triangle.2.circlepath"
        case .needsReview: "circle.dotted"
        case .approved: "checkmark.circle.fill"
        case .ignored: "eye.slash.fill"
        }
    }
}

enum ReviewFilter: String, CaseIterable, Identifiable {
    case needsReview = "Review"
    case approved = "Approved"
    case ignored = "Ignored"
    case all = "All"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .needsReview: "circle.dotted"
        case .approved: "checkmark.circle"
        case .ignored: "eye.slash"
        case .all: "tray.full"
        }
    }
}
