import Foundation

enum SourceEditorError: LocalizedError {
    case sourceChanged
    case invalidRange
    case unsupportedInterpolation
    case unsupportedControlCharacter

    var errorDescription: String? {
        switch self {
        case .sourceChanged: "The file changed on disk. Refresh the project and reapply your edit."
        case .invalidRange: "The string could not be found at its original location."
        case .unsupportedControlCharacter: "The replacement contains an unsupported control character."
        case .unsupportedInterpolation: "This literal uses syntax that cannot safely be edited in place."
        }
    }
}

struct SourceEditor: Sendable {
    static func readSource(at url: URL) throws -> (String, String.Encoding) {
        let data = try Data(contentsOf: url)
        if let source = String(data: data, encoding: .utf8) { return (source, .utf8) }
        if url.pathExtension.lowercased() == "strings", data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let source = String(data: data, encoding: .utf16) {
            return (source, data.starts(with: [0xff, 0xfe]) ? .utf16LittleEndian : .utf16BigEndian)
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    func replace(_ occurrence: StringOccurrence, with newValue: String) throws {
        guard occurrence.isEditable else { throw SourceEditorError.unsupportedInterpolation }
        guard !newValue.unicodeScalars.contains(where: {
            $0.value < 32 && ![9, 10, 13].contains($0.value)
        }) else { throw SourceEditorError.unsupportedControlCharacter }
        let (source, encoding) = try Self.readSource(at: occurrence.fileURL)
        guard Hashing.sha256(source) == occurrence.sourceFingerprint else {
            throw SourceEditorError.sourceChanged
        }

        let mutable = NSMutableString(string: source)
        guard occurrence.contentRange.location >= 0,
              occurrence.contentRange.location <= mutable.length,
              occurrence.contentRange.length >= 0,
              occurrence.contentRange.length <= mutable.length - occurrence.contentRange.location,
              mutable.substring(with: occurrence.contentRange) == occurrence.rawValue else {
            throw SourceEditorError.invalidRange
        }

        mutable.replaceCharacters(
            in: occurrence.contentRange,
            with: LiteralCodec.encode(newValue, style: occurrence.style)
        )
        guard var data = (mutable as String).data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if encoding == .utf16LittleEndian { data.insert(contentsOf: [0xff, 0xfe], at: 0) }
        if encoding == .utf16BigEndian { data.insert(contentsOf: [0xfe, 0xff], at: 0) }
        try data.write(to: occurrence.fileURL, options: .atomic)
    }

}

// Decode escapes once, in source order. Chained replacements confuse "\\\\n"
// (a literal backslash followed by n) with a newline and silently change edits.
enum LiteralCodec {
    static func decode(_ raw: String, style: StringOccurrence.LiteralStyle,
                       language: StringOccurrence.Language) -> (value: String, supported: Bool) {
        if style == .htmlText || style == .htmlAttribute {
            var supported = true
            let expression = try! NSRegularExpression(pattern: "&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);")
            let result = NSMutableString(string: raw)
            for match in expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed() {
                let entity = (raw as NSString).substring(with: match.range)
                let named = ["&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&amp;": "&", "&nbsp;": "\u{00a0}"]
                var replacement = named[entity]
                if entity.hasPrefix("&#") {
                    let hex = entity.lowercased().hasPrefix("&#x")
                    let digits = entity.dropFirst(hex ? 3 : 2).dropLast()
                    if let number = UInt32(digits, radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) {
                        replacement = String(scalar)
                    }
                }
                if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
                else { supported = false }
            }
            return (result as String, supported)
        }
        if language == .json || language == .stringCatalog {
            if let data = ("\"" + raw + "\"").data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                return (value, true)
            }
            return (raw, false)
        }
        let chars = Array(raw.unicodeScalars)
        var output = ""
        var index = 0
        var supported = true
        while index < chars.count {
            let char = chars[index]
            index += 1
            guard char == "\\" else { output.unicodeScalars.append(char); continue }
            guard index < chars.count else { return (raw, false) }
            let escape = chars[index]
            index += 1
            let simple: [UnicodeScalar: String] = ["n": "\n", "r": "\r", "t": "\t", "0": "\0", "\\": "\\", "\"": "\"", "'": "'", "b": "\u{8}", "f": "\u{c}", "v": "\u{b}", "`": "`", "$": "$", "/": "/"]
            if let value = simple[escape] { output += value; continue }
            if escape == "\n" { continue }
            if escape == "u" || escape == "U" || escape == "x" {
                let braced = index < chars.count && chars[index] == "{"
                if braced { index += 1 }
                let start = index
                if braced {
                    while index < chars.count && chars[index] != "}" { index += 1 }
                } else {
                    // Objective-C universal character names use eight digits for
                    // uppercase U; legacy .strings escapes still use four.
                    let count = escape == "x" ? 2 : (escape == "U" && language == .objectiveC ? 8 : 4)
                    guard index + count <= chars.count else { return (raw, false) }
                    index += count
                }
                let digits = String(String.UnicodeScalarView(chars[start..<index]))
                if (!braced || index < chars.count), let number = UInt32(digits, radix: 16), let scalar = UnicodeScalar(number) {
                    output.unicodeScalars.append(scalar)
                    if braced { index += 1 }
                    continue
                }
            }
            // Preserve unfamiliar syntax for review, but never rewrite its decoded value.
            supported = false
            output += "\\" + String(escape)
        }
        return supported ? (output, true) : (raw, false)
    }

    static func encode(_ value: String, style: StringOccurrence.LiteralStyle) -> String {
        if style == .htmlText || style == .htmlAttribute {
            return value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "{", with: "&#123;")
                .replacingOccurrences(of: "}", with: "&#125;")
        }
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"" where style == .doubleQuoted: result += "\\\""
            case "'" where style == .singleQuoted: result += "\\'"
            case "`" where style == .template: result += "\\`"
            case "$" where style == .template: result += "\\$"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{8}": result += "\\b"
            case "\u{c}": result += "\\f"
            case _ where scalar.value < 32:
                // Universal control escapes differ between Swift and JSON/JavaScript.
                // Reject these in replace instead of emitting invalid source.
                result.unicodeScalars.append(scalar)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
