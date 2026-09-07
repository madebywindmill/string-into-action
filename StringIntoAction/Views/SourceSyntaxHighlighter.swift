import AppKit
import SwiftUI

@MainActor
enum SourceSyntaxHighlighter {
    private struct Rule {
        let expression: NSRegularExpression
        let color: NSColor
        let captureGroup: Int

        init(_ pattern: String, color: NSColor, captureGroup: Int = 0) {
            // Every pattern in this file is a developer-authored constant.
            expression = try! NSRegularExpression(pattern: pattern)
            self.color = color
            self.captureGroup = captureGroup
        }
    }

    static func highlight(_ source: String, as language: StringOccurrence.Language) -> AttributedString {
        let output = NSMutableAttributedString(
            string: source,
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        var claimed = Array(repeating: false, count: output.length)

        switch language {
        case .swift, .objectiveC, .javascript, .typescript:
            applyCodeLexemes(to: output, source: source, claimed: &claimed)
            apply(codeRules(for: language), to: output, source: source, claimed: &claimed)

        case .html, .interfaceBuilder:
            applyMarkupLexemes(to: output, source: source, claimed: &claimed)
            apply(markupRules, to: output, source: source, claimed: &claimed)

        case .json, .stringCatalog:
            applyJSONLexemes(to: output, source: source, claimed: &claimed)
            apply(jsonRules, to: output, source: source, claimed: &claimed)

        case .strings:
            applyCodeLexemes(to: output, source: source, claimed: &claimed)
        }

        return AttributedString(output)
    }

    private static func applyCodeLexemes(
        to output: NSMutableAttributedString,
        source: String,
        claimed: inout [Bool]
    ) {
        applyLexemes(
            #"//.*|/\*.*?(?:\*/|$)|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#,
            to: output,
            source: source,
            claimed: &claimed
        ) { token in
            token.hasPrefix("//") || token.hasPrefix("/*") ? .secondaryLabelColor : .systemRed
        }
    }

    private static func applyMarkupLexemes(
        to output: NSMutableAttributedString,
        source: String,
        claimed: inout [Bool]
    ) {
        applyLexemes(
            #"<!--.*?(?:-->|$)|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#,
            to: output,
            source: source,
            claimed: &claimed
        ) { token in
            token.hasPrefix("<!--") ? .secondaryLabelColor : .systemRed
        }
    }

    private static func applyJSONLexemes(
        to output: NSMutableAttributedString,
        source: String,
        claimed: inout [Bool]
    ) {
        let keyRule = Rule(#""(?:\\.|[^"\\])*"(?=\s*:)"#, color: .systemBlue)
        apply([keyRule], to: output, source: source, claimed: &claimed)
        applyLexemes(
            #"//.*|/\*.*?(?:\*/|$)|"(?:\\.|[^"\\])*""#,
            to: output,
            source: source,
            claimed: &claimed
        ) { token in
            token.hasPrefix("//") || token.hasPrefix("/*") ? .secondaryLabelColor : .systemRed
        }
    }

    private static func applyLexemes(
        _ pattern: String,
        to output: NSMutableAttributedString,
        source: String,
        claimed: inout [Bool],
        color: (String) -> NSColor
    ) {
        let expression = try! NSRegularExpression(pattern: pattern)
        let sourceString = source as NSString
        let fullRange = NSRange(location: 0, length: sourceString.length)

        for match in expression.matches(in: source, range: fullRange) {
            let range = match.range
            guard canClaim(range, in: claimed) else { continue }
            output.addAttribute(.foregroundColor, value: color(sourceString.substring(with: range)), range: range)
            claim(range, in: &claimed)
        }
    }

    private static func apply(
        _ rules: [Rule],
        to output: NSMutableAttributedString,
        source: String,
        claimed: inout [Bool]
    ) {
        let fullRange = NSRange(location: 0, length: output.length)
        for rule in rules {
            for match in rule.expression.matches(in: source, range: fullRange) {
                let range = match.range(at: rule.captureGroup)
                guard canClaim(range, in: claimed) else { continue }
                output.addAttribute(.foregroundColor, value: rule.color, range: range)
                claim(range, in: &claimed)
            }
        }
    }

    private static func canClaim(_ range: NSRange, in claimed: [Bool]) -> Bool {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= claimed.count else { return false }
        return !claimed[range.location..<NSMaxRange(range)].contains(true)
    }

    private static func claim(_ range: NSRange, in claimed: inout [Bool]) {
        for index in range.location..<NSMaxRange(range) {
            claimed[index] = true
        }
    }

    private static func codeRules(for language: StringOccurrence.Language) -> [Rule] {
        let keywords: String
        switch language {
        case .swift:
            keywords = "actor|any|as|associatedtype|async|await|break|case|catch|class|continue|convenience|default|defer|deinit|didSet|do|else|enum|extension|fallthrough|false|fileprivate|final|for|func|get|guard|if|import|in|indirect|init|inout|internal|is|isolated|lazy|let|macro|mutating|nil|nonisolated|open|operator|override|private|protocol|public|repeat|required|rethrows|return|self|Self|set|some|static|struct|subscript|super|switch|throw|throws|true|try|typealias|var|weak|where|while|willSet"
        case .objectiveC:
            keywords = "@autoreleasepool|@catch|@class|@dynamic|@encode|@end|@finally|@implementation|@interface|@optional|@package|@private|@property|@protected|@protocol|@public|@required|@selector|@synchronized|@synthesize|@throw|@try|BOOL|break|case|char|const|continue|default|do|double|else|enum|false|float|for|id|if|int|long|nil|NO|return|self|short|signed|sizeof|static|struct|super|switch|true|typedef|union|unsigned|void|while|YES"
        case .javascript, .typescript:
            keywords = "as|async|await|break|case|catch|class|const|constructor|continue|debugger|declare|default|delete|do|else|enum|export|extends|false|finally|for|from|function|get|if|implements|import|in|instanceof|interface|keyof|let|namespace|new|null|of|private|protected|public|readonly|return|set|static|super|switch|this|throw|true|try|type|typeof|undefined|var|void|while|with|yield"
        default:
            return []
        }

        return [
            Rule("(?<![A-Za-z0-9_])(?:\(keywords))(?![A-Za-z0-9_])", color: .systemPink),
            Rule(#"(?:@|#)[A-Za-z_][A-Za-z0-9_]*"#, color: .systemPurple),
            Rule(#"\b(?:0x[0-9A-Fa-f]+|0b[01]+|\d+(?:\.\d+)?)\b"#, color: .systemBlue),
            Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, color: .systemTeal),
            Rule(#"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, color: .systemBlue),
            Rule(#"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, color: .systemIndigo)
        ]
    }

    private static let markupRules = [
        Rule(#"</?\s*([A-Za-z][A-Za-z0-9:_-]*)"#, color: .systemPink, captureGroup: 1),
        Rule(#"</?|/?>"#, color: .systemPink),
        Rule(#"\b[A-Za-z_:][A-Za-z0-9:._-]*(?=\s*=)"#, color: .systemBlue),
        Rule(#"&(?:#\d+|#x[0-9A-Fa-f]+|[A-Za-z]+);"#, color: .systemPurple)
    ]

    private static let jsonRules = [
        Rule(#"(?<![A-Za-z0-9_])(?:true|false|null)(?![A-Za-z0-9_])"#, color: .systemPink),
        Rule(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemBlue)
    ]
}
