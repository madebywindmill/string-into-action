import Foundation

struct ScanResult: Sendable {
    let occurrences: [StringOccurrence]
    let filesScanned: Int
}

struct StringScanner: Sendable {
    private struct Classification: Sendable {
        let confidence: StringOccurrence.Confidence
        let reason: String
        let role: StringOccurrence.LiteralRole
    }

    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "build", "DerivedData", "node_modules",
        "Pods", "Carthage", "vendor", "dist", ".next", ".idea", "xcuserdata"
    ]

    private static let supportedExtensions: Set<String> = [
        "swift", "m", "mm", "strings", "xcstrings", "storyboard", "xib",
        "js", "jsx", "ts", "tsx", "html", "htm", "vue", "svelte", "json"
    ]

    func scan(projectURL: URL) -> ScanResult {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return ScanResult(occurrences: [], filesScanned: 0) }

        var output: [StringOccurrence] = []
        var filesScanned = 0

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values?.isDirectory == true {
                if Self.ignoredDirectories.contains(url.lastPathComponent) || values?.isHidden == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true,
                  (values?.fileSize ?? 0) < 2_000_000,
                  Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let (source, _) = try? SourceEditor.readSource(at: url) else { continue }

            filesScanned += 1
            let relativePath = relativePath(for: url, projectURL: projectURL)
            output.append(contentsOf: scanFile(url: url, relativePath: relativePath, source: source))
        }

        return ScanResult(
            occurrences: output.sorted {
                if $0.relativePath == $1.relativePath { return $0.contentRange.location < $1.contentRange.location }
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            },
            filesScanned: filesScanned
        )
    }

    private func scanFile(url: URL, relativePath: String, source: String) -> [StringOccurrence] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "strings":
            return matches(
                pattern: #"\"(?:\\.|[^\"\\])*\"\s*=\s*\"((?:\\.|[^\"\\])*)\"\s*;"#,
                captureGroup: 1, source: source, url: url, relativePath: relativePath,
                language: .strings, style: .doubleQuoted, applyHeuristics: false,
                excludedRanges: commentRanges(in: source)
            )
        case "xcstrings":
            guard let data = source.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let strings = root["strings"] as? [String: Any] else { return [] }
            return occurrences(from: catalogCandidates(in: source, keys: Set(strings.keys)),
                               source: source, url: url, relativePath: relativePath,
                               language: .stringCatalog, applyHeuristics: false)
        case "storyboard", "xib":
            let excludedRanges: [NSRange]
            if url.lastPathComponent.caseInsensitiveCompare("Main.storyboard") == .orderedSame,
               let mainMenu = mainMenuRange(in: source) {
                excludedRanges = [mainMenu] + markupExcludedRanges(in: source)
            } else {
                excludedRanges = markupExcludedRanges(in: source)
            }
            return matches(
                pattern: #"(?:text|title|placeholder|toolTip|label)=\"([^\"]+)\""#,
                captureGroup: 1, source: source, url: url, relativePath: relativePath,
                language: .interfaceBuilder, style: .htmlAttribute, applyHeuristics: true,
                excludedRanges: excludedRanges
            )
        case "swift", "m", "mm", "js", "jsx", "ts", "tsx":
            let language: StringOccurrence.Language = switch ext {
            case "swift": .swift
            case "m", "mm": .objectiveC
            case "ts", "tsx": .typescript
            default: .javascript
            }
            let literals = codeLiterals(in: source, language: language, supportsJSX: ext == "jsx" || ext == "tsx")
            return occurrences(from: literals, source: source,
                               url: url, relativePath: relativePath, language: language,
                               applyHeuristics: true)
        case "html", "htm", "vue", "svelte":
            return matches(
                pattern: #">([^<>{}\n][^<>{}]*)<"#, captureGroup: 1, source: source,
                url: url, relativePath: relativePath, language: .html,
                style: .htmlText, applyHeuristics: true,
                excludedRanges: markupExcludedRanges(in: source)
            )
        case "json":
            let lowerPath = relativePath.lowercased()
            let translationHints = ["locale", "localization", "translation", "i18n", "strings", "messages", "/lang/"]
            guard translationHints.contains(where: { lowerPath.contains($0) }) else { return [] }
            return matches(
                pattern: #":\s*\"((?:\\.|[^\"\\])*)\""#, captureGroup: 1, source: source,
                url: url, relativePath: relativePath, language: .json,
                style: .doubleQuoted, applyHeuristics: true
            )
        default:
            return []
        }
    }

    private func matches(
        pattern: String,
        captureGroup: Int,
        source: String,
        url: URL,
        relativePath: String,
        language: StringOccurrence.Language,
        style: StringOccurrence.LiteralStyle,
        applyHeuristics: Bool,
        forceReadOnly: Bool = false,
        excludedRanges: [NSRange] = []
    ) -> [StringOccurrence] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let candidates = expression.matches(in: source, range: fullRange).compactMap { match -> LiteralCandidate? in
            let range = match.range(at: captureGroup)
            guard range.location != NSNotFound,
                  !excludedRanges.contains(where: { NSIntersectionRange(range, $0).length > 0 }) else { return nil }
            return LiteralCandidate(range: range, style: style, readOnly: forceReadOnly)
        }
        return occurrences(from: candidates, source: source, url: url, relativePath: relativePath,
                           language: language, applyHeuristics: applyHeuristics)
    }

    private struct LiteralCandidate {
        let range: NSRange
        let style: StringOccurrence.LiteralStyle
        var readOnly = false
    }

    private func occurrences(from candidates: [LiteralCandidate], source: String, url: URL,
                             relativePath: String, language: StringOccurrence.Language,
                             applyHeuristics: Bool) -> [StringOccurrence] {
        let nsSource = source as NSString
        let sourceFingerprint = Hashing.sha256(source)
        let lines = source.components(separatedBy: "\n")
        var lineStarts = [0]
        for (index, char) in source.utf16.enumerated() where char == 10 { lineStarts.append(index + 1) }
        // A lightweight declaration anchor reduces matches across unrelated scopes.
        var declaration = ""
        let scopes = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.range(of: #"\b(func|function|class|struct|enum|extension)\s+[A-Za-z_]"#, options: .regularExpression) != nil {
                declaration = String(trimmed.split(separator: "{", maxSplits: 1).first ?? "")
            }
            return declaration
        }
        return candidates.compactMap { candidate in
            let range = candidate.range
            let style = candidate.style
            let rawValue = nsSource.substring(with: range)
            let decoded = LiteralCodec.decode(rawValue, style: style, language: language)
            let value = candidate.readOnly && language != .stringCatalog ? rawValue : decoded.value
            guard value.contains(where: { $0.isWhitespace }) else { return nil }
            var low = 0
            var high = lineStarts.count
            while low + 1 < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= range.location { low = middle } else { high = middle }
            }
            let position = (line: low + 1, column: range.location - lineStarts[low] + 1)
            let lineText = lines[low]
            let nearbyPrefixStart = max(0, range.location - 600)
            let nearbyPrefix = nsSource.substring(
                with: NSRange(location: nearbyPrefixStart, length: range.location - nearbyPrefixStart)
            )

            let classification: Classification
            if applyHeuristics {
                guard let result = classify(
                    value,
                    rawValue: rawValue,
                    lineText: lineText,
                    column: position.column,
                    nearbyPrefix: nearbyPrefix,
                    language: language,
                    style: style
                ) else { return nil }
                classification = result
            } else {
                classification = defaultClassification(for: language)
            }

            let identity = "\(relativePath):\(position.line):\(position.column)"
            let wholeLines = nsSource.lineRange(for: range)
            let prefix = nsSource.substring(with: NSRange(location: wholeLines.location, length: range.location - wholeLines.location))
            let suffix = nsSource.substring(with: NSRange(location: NSMaxRange(range), length: NSMaxRange(wholeLines) - NSMaxRange(range)))
            let template = (prefix + "<string>" + suffix).components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let structure = Hashing.sha256("\(language.rawValue)|\(style)|\(classification.role.rawValue)|\(scopes[low])|\(template)")
            let endLine = min(lines.count - 1, low + rawValue.filter { $0 == "\n" }.count)
            let before = lines[max(0, low - 3)..<low]
            let after = lines[(endLine + 1)..<min(lines.count, endLine + 4)]
            let neighborhood = Hashing.sha256((Array(before) + [template] + Array(after))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines))
            return StringOccurrence(
                id: identity,
                fileURL: url,
                relativePath: relativePath,
                line: position.line,
                column: position.column,
                value: value,
                rawValue: rawValue,
                contextLines: (max(1, position.line - 6)...min(lines.count, position.line + 6)).map {
                    ContextLine(number: $0, text: lines[$0 - 1], isSelected: $0 == position.line)
                },
                contentRange: range,
                sourceFingerprint: sourceFingerprint,
                language: language,
                style: style,
                isEditable: !candidate.readOnly && decoded.supported,
                confidence: classification.confidence,
                detectionReason: classification.reason,
                role: classification.role,
                structureFingerprint: structure,
                neighborhoodFingerprint: neighborhood
            )
        }
    }

    // Consume each literal once so quotes inside another literal or a comment
    // cannot become editable occurrences. Complex Swift/template syntax is read-only.
    private func codeLiterals(in source: String, language: StringOccurrence.Language,
                              supportsJSX: Bool = false) -> [LiteralCandidate] {
        let units = Array(source.utf16)
        var index = 0
        var result: [LiteralCandidate] = []
        func has(_ text: String, at offset: Int) -> Bool {
            let target = Array(text.utf16)
            return offset >= 0 && offset + target.count <= units.count
                && units[offset..<(offset + target.count)].elementsEqual(target)
        }
        func skipComment() -> Bool {
            if has("//", at: index) {
                while index < units.count && units[index] != 10 { index += 1 }
                return true
            }
            if has("/*", at: index) {
                index += 2
                var depth = 1
                while index < units.count && depth > 0 {
                    if has("/*", at: index), language == .swift { depth += 1; index += 2 }
                    else if has("*/", at: index) { depth -= 1; index += 2 }
                    else { index += 1 }
                }
                return true
            }
            return false
        }
        func consumeLiteral() -> LiteralCandidate? {
            let start = index
            var hashes = 0
            if language == .swift {
                while index < units.count && units[index] == 35 { hashes += 1; index += 1 }
            }
            guard index < units.count else { return nil }
            let quote = units[index]
            guard quote == 34 || ((language == .javascript || language == .typescript) && (quote == 39 || quote == 96)) else {
                index = start
                return nil
            }
            let triple = language == .swift && has("\"\"\"", at: index)
            let delimiter = String(repeating: String(UnicodeScalar(quote)!), count: triple ? 3 : 1)
                + String(repeating: "#", count: hashes)
            index += triple ? 3 : 1
            let contentStart = index
            var readOnly = triple || hashes > 0
            while index < units.count {
                if has(delimiter, at: index) {
                    let range = NSRange(location: contentStart, length: index - contentStart)
                    index += delimiter.utf16.count
                    return LiteralCandidate(range: range, style: quote == 96 ? .template : (quote == 39 ? .singleQuoted : .doubleQuoted), readOnly: readOnly)
                }
                let swiftInterpolation = language == .swift && has("\\" + String(repeating: "#", count: hashes) + "(", at: index)
                let webInterpolation = quote == 96 && has("${", at: index)
                if swiftInterpolation || webInterpolation {
                    readOnly = true
                    index += swiftInterpolation ? hashes + 2 : 2
                    let opening: UInt16 = swiftInterpolation ? 40 : 123
                    let closing: UInt16 = swiftInterpolation ? 41 : 125
                    var depth = 1
                    while index < units.count && depth > 0 {
                        if skipComment() { continue }
                        if consumeLiteral() != nil { continue }
                        guard index < units.count else { break }
                        if units[index] == opening { depth += 1 }
                        if units[index] == closing { depth -= 1 }
                        index += 1
                    }
                } else if has("\\" + String(repeating: "#", count: hashes), at: index) {
                    index = min(units.count, index + hashes + 2)
                } else { index += 1 }
            }
            return nil
        }
        func skipRegex() -> Bool {
            if units[index] == 47 {
                let prefix = String(decoding: units[max(0, index - 100)..<index], as: UTF16.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let mayStartRegex = prefix.isEmpty || prefix.last.map { "=(:,[!&|?{;".contains($0) } == true
                    || prefix.hasSuffix("return") || prefix.hasSuffix("case")
                if mayStartRegex {
                    var end = index + 1
                    var inClass = false
                    while end < units.count && units[end] != 10 {
                        if units[end] == 92 { end += 2; continue }
                        if units[end] == 91 { inClass = true }
                        if units[end] == 93 { inClass = false }
                        if units[end] == 47 && !inClass { break }
                        end += 1
                    }
                    if end < units.count && units[end] == 47 { index = end + 1; return true }
                }
            }
            return false
        }
        func collectLiteral() -> Bool {
            let start = index
            if var literal = consumeLiteral() {
                if literal.style == .template {
                    let prefix = String(decoding: units[max(0, start - 100)..<start], as: UTF16.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let last = prefix.last, last.isLetter || last.isNumber || last == ")" || last == "]" {
                        literal.readOnly = true
                    }
                }
                if language != .objectiveC || (start > 0 && units[start - 1] == 64) {
                    result.append(literal)
                }
                return true
            }
            return index != start
        }
        func skipWhitespace() {
            while index < units.count && [9, 10, 13, 32].contains(units[index]) { index += 1 }
        }
        func jsxName() -> String? {
            let start = index
            guard index < units.count,
                  units[index] == 95 || (65...90).contains(units[index]) || (97...122).contains(units[index]) else { return nil }
            while index < units.count {
                let unit = units[index]
                guard (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit)
                        || [95, 36, 45, 46, 58].contains(unit) else { break }
                index += 1
            }
            return String(decoding: units[start..<index], as: UTF16.self)
        }
        func consumeJSXExpression(depth: Int) -> Bool {
            guard depth < 128, has("{", at: index) else { return false }
            index += 1
            while index < units.count {
                if skipComment() || skipRegex() || collectLiteral() { continue }
                if has("}", at: index) { index += 1; return true }
                if has("{", at: index) {
                    guard consumeJSXExpression(depth: depth + 1) else { return false }
                    continue
                }
                if has("<", at: index), consumeJSX(depth: depth + 1) { continue }
                index += 1
            }
            return false
        }
        func consumeJSX(depth: Int = 0) -> Bool {
            guard supportsJSX, depth < 128, has("<", at: index) else { return false }
            let start = index
            let firstCandidate = result.count
            var complete = false
            defer {
                // A comparison or TypeScript generic must not become markup.
                if !complete {
                    index = start
                    result.removeSubrange(firstCandidate...)
                }
            }
            index += 1
            let fragment = has(">", at: index)
            let name = fragment ? "" : jsxName()
            guard let name else { return false }
            while !fragment {
                skipWhitespace()
                if has("/>", at: index) { index += 2; complete = true; return true }
                if has(">", at: index) { break }
                if has("{", at: index) {
                    guard consumeJSXExpression(depth: depth + 1) else { return false }
                    continue
                }
                guard jsxName() != nil else { return false }
                skipWhitespace()
                guard has("=", at: index) else { continue } // Boolean attribute.
                index += 1
                skipWhitespace()
                if has("{", at: index) {
                    guard consumeJSXExpression(depth: depth + 1) else { return false }
                } else {
                    guard index < units.count, units[index] == 34 || units[index] == 39 else { return false }
                    let quote = units[index]
                    index += 1
                    let contentStart = index
                    // Backslashes are literal in JSX attributes, even before a quote.
                    while index < units.count && units[index] != quote { index += 1 }
                    guard index < units.count else { return false }
                    result.append(LiteralCandidate(range: NSRange(location: contentStart, length: index - contentStart),
                                                   style: .htmlAttribute))
                    index += 1
                }
            }
            index += 1 // Opening tag's >.
            while index < units.count {
                if has("</", at: index) {
                    index += 2
                    if !fragment { guard jsxName() == name else { return false } }
                    skipWhitespace()
                    guard has(">", at: index) else { return false }
                    index += 1
                    complete = true
                    return true
                }
                if has("<", at: index) {
                    guard consumeJSX(depth: depth + 1) else { return false }
                } else if has("{", at: index) {
                    guard consumeJSXExpression(depth: depth + 1) else { return false }
                } else {
                    let contentStart = index
                    while index < units.count && units[index] != 60 && units[index] != 123 { index += 1 }
                    result.append(LiteralCandidate(range: NSRange(location: contentStart, length: index - contentStart),
                                                   style: .htmlText))
                }
            }
            return false
        }
        while index < units.count {
            if skipComment() || skipRegex() || consumeJSX() || collectLiteral() { continue }
            index += 1
        }
        return result
    }

    private func commentRanges(in source: String) -> [NSRange] {
        // Match quoted tokens too, so comment delimiters inside values stay literal.
        let expression = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/"#)
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            let token = (source as NSString).substring(with: $0.range)
            return token.hasPrefix("/") ? $0.range : nil
        }
    }

    private func markupExcludedRanges(in source: String) -> [NSRange] {
        let expression = try! NSRegularExpression(
            pattern: #"<!--[\s\S]*?-->|<(script|style)\b[^>]*>[\s\S]*?</\1\s*>"#,
            options: .caseInsensitive
        )
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map(\.range)
    }

    private func catalogCandidates(in source: String, keys: Set<String>) -> [LiteralCandidate] {
        let expression = try! NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"|[{}\[\],:]"#)
        let tokens = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let nsSource = source as NSString
        var depth = 0
        var stringsDepth: Int?
        var previous = ""
        var pendingStrings = false
        var result: [LiteralCandidate] = []
        for token in tokens {
            let text = nsSource.substring(with: token.range)
            if text == "{" || text == "[" {
                depth += 1
                if pendingStrings && text == "{" { stringsDepth = depth }
                pendingStrings = false
            } else if text == "}" || text == "]" {
                if stringsDepth == depth { stringsDepth = nil }
                depth -= 1
            } else if text.hasPrefix("\"") {
                let isKey = previous == "{" || previous == ","
                let raw = nsSource.substring(with: token.range(at: 1))
                let value = LiteralCodec.decode(raw, style: .doubleQuoted, language: .stringCatalog).value
                if depth == 1 && isKey && value == "strings" { pendingStrings = true }
                if depth == stringsDepth && isKey && keys.contains(value) {
                    result.append(LiteralCandidate(range: token.range(at: 1), style: .doubleQuoted, readOnly: true))
                }
            }
            previous = text
        }
        return result
    }

    private func defaultClassification(for language: StringOccurrence.Language) -> Classification {
        switch language {
        case .strings, .stringCatalog, .json:
            Classification(confidence: .review, reason: "Declared in a localization resource", role: .localization)
        case .interfaceBuilder:
            Classification(confidence: .review, reason: "Displayed by an Interface Builder control", role: .interfaceBuilder)
        case .html:
            Classification(confidence: .review, reason: "Visible text in web markup", role: .webContent)
        default:
            Classification(confidence: .review, reason: "Looks like natural-language copy", role: .unknown)
        }
    }

    private func classify(
        _ value: String,
        rawValue: String,
        lineText: String,
        column: Int,
        nearbyPrefix: String,
        language: StringOccurrence.Language,
        style: StringOccurrence.LiteralStyle
    ) -> Classification? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .letters) != nil else { return nil }

        if language == .json || language == .interfaceBuilder || language == .html {
            return defaultClassification(for: language)
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") { return nil }
        if lower.hasPrefix("com.") || lower.hasPrefix("org.") || lower.hasPrefix("net.") { return nil }
        if trimmed.hasPrefix("./") || trimmed.hasPrefix("../") || trimmed.hasPrefix("/") { return nil }
        if trimmed.range(of: #"^[a-z0-9_.-]+\.(png|jpg|jpeg|svg|json|plist|xcassets|storyboard|xib)$"#, options: .regularExpression) != nil { return nil }

        let nsLine = lineText as NSString
        let contentOffset = max(0, min(nsLine.length, column - 1))
        let prefix = nsLine.substring(to: contentOffset)
        let suffixOffset = min(nsLine.length, contentOffset + rawValue.utf16.count)
        let suffix = nsLine.substring(from: suffixOffset)
        let normalizedLine = lineText.lowercased()


        let hardCodeMarkers = [
            "notification.name", "case \"", "import(", "require(",
            "font-family", "content-type", "application/json", "logger.", "os_log(",
            "debugprint(", "precondition(", "assert(", "fatalerror("
        ]
        if hardCodeMarkers.contains(where: { normalizedLine.contains($0) }) { return nil }
        if isLoggingCall(nearbyPrefix: nearbyPrefix) { return nil }

        let argumentLabel = capture(
            pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[@#]*[\"'`]*$"#,
            in: prefix
        )?.lowercased()
        let structuralLabels: Set<String> = [
            "id", "key", "flag", "before", "after", "from", "to", "identifier",
            "forresource", "forkey", "named", "systemname", "systemsymbolname",
            "imagenamed", "resourcename", "rawvalue", "type",
            "path", "filename", "extension", "selector", "keypath",
            "reuseidentifier", "notification", "event", "metric"
        ]
        if let argumentLabel, structuralLabels.contains(argumentLabel) { return nil }

        let structuralSyntax = [
            prefix.range(of: #"(?:==|!=|<=|>=)\s*[@#]*[\"'`]*$"#, options: .regularExpression) != nil,
            suffix.range(of: #"^[\"'`]\s*(?:==|!=|<=|>=)"#, options: .regularExpression) != nil,
            prefix.range(of: #"\[\s*[\"'`]*$"#, options: .regularExpression) != nil
                && suffix.range(of: #"^[\"'`]\s*\]"#, options: .regularExpression) != nil
        ]
        if structuralSyntax.contains(true) { return nil }

        if style == .htmlText {
            return Classification(confidence: .review, reason: "Visible text in web markup", role: .webContent)
        }
        if language == .interfaceBuilder {
            return Classification(confidence: .review, reason: "Displayed by an Interface Builder control", role: .interfaceBuilder)
        }

        let localizationMarkers = ["nslocalizedstring(", "string(localized:", "localizedstringkey("]
        if localizationMarkers.contains(where: { normalizedLine.contains($0) }) {
            return Classification(confidence: .review, reason: "Passed to a localization API", role: .localization)
        }

        let uiMarkers = [
            "text(", "label(", "button(", "navigationtitle(", "alert(", "menu(",
            "section(", "toggle(", "textfield(", "securefield(", "link(",
            "accessibilitylabel(", "accessibilityhint(", "help(", "title:",
            "accessibilitydescription:", "accessibilitylabel:", "accessibilityhint:",
            "message:", "prompt:", "placeholder:", "messagetext", "informativetext",
            ".title =", ".stringvalue =", "settitle("
        ]
        if uiMarkers.contains(where: { normalizedLine.contains($0) }) {
            return Classification(confidence: .review, reason: "Passed directly to a UI API", role: .userInterface)
        }

        let hasWhitespaceOrPunctuation = trimmed.contains(where: { $0.isWhitespace || $0.isPunctuation })
        let startsLikeSentence = trimmed.first?.isUppercase == true
        if hasWhitespaceOrPunctuation && startsLikeSentence {
            return Classification(confidence: .review, reason: "Looks like natural-language copy", role: .message)
        }

        let identifierPatterns = [
            #"^[a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*$"#,
            #"^[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+$"#,
            #"^[a-z][a-z0-9]*-[a-z0-9-]+$"#,
            #"^[a-z][A-Za-z0-9.]+$"#
        ]
        if identifierPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
            return Classification(confidence: .possible, reason: "No direct connection to the UI was found", role: .unknown)
        }

        return Classification(
            confidence: .possible,
            reason: "No direct connection to the UI was found",
            role: .unknown
        )
    }

    private func capture(pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private func isLoggingCall(nearbyPrefix: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b([A-Za-z_][A-Za-z0-9_.]*)\s*\("#
        ) else { return false }
        let matches = expression.matches(
            in: nearbyPrefix,
            range: NSRange(nearbyPrefix.startIndex..., in: nearbyPrefix)
        )
        let nsPrefix = nearbyPrefix as NSString
        guard let match = matches.last(where: { match in
            let tail = nsPrefix.substring(from: NSMaxRange(match.range))
            var depth = 1
            for character in tail {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth == 0 { return false }
            }
            return true
        }),
              let range = Range(match.range(at: 1), in: nearbyPrefix) else { return false }

        let callee = String(nearbyPrefix[range])
        let components = callee.split(separator: ".").map(String.init)
        guard let function = components.last else { return false }
        let lowerFunction = function.lowercased()
        let directLoggingFunctions: Set<String> = [
            "log", "nslog", "nslogv", "os_log", "os_log_with_type", "print", "printf",
            "debugprint", "dump", "fprintf", "fputs", "puts"
        ]
        if directLoggingFunctions.contains(lowerFunction) || lowerFunction.hasSuffix("log") {
            return true
        }

        let loggingLevelSuffixes = [
            "trace", "debug", "info", "notice", "warning", "warn", "error", "critical", "fault", "verbose"
        ]
        if lowerFunction.contains("log"), loggingLevelSuffixes.contains(where: { lowerFunction.hasSuffix($0) }) {
            return true
        }

        let consoleMethods: Set<String> = ["log", "debug", "info", "warn", "error", "trace"]
        if components.dropLast().last?.lowercased() == "console",
           consoleMethods.contains(lowerFunction) {
            return true
        }

        let loggerMethods = Set(loggingLevelSuffixes)
        let receiverLooksLikeLogger = components.dropLast().contains {
            let component = $0.lowercased()
            return component == "log" || component.contains("logger")
        }
        return receiverLooksLikeLogger && loggerMethods.contains(lowerFunction)
    }

    private func mainMenuRange(in source: String) -> NSRange? {
        guard let expression = try? NSRegularExpression(
            pattern: #"<menu\b[^>]*>|</menu\s*>"#,
            options: [.caseInsensitive]
        ) else { return nil }

        let nsSource = source as NSString
        let tags = expression.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        var startLocation: Int?
        var depth = 0

        for match in tags {
            let tag = nsSource.substring(with: match.range)
            let isClosing = tag.lowercased().hasPrefix("</menu")
            let isSelfClosing = tag.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>")

            if startLocation == nil {
                guard !isClosing,
                      tag.range(of: #"key\s*=\s*\"mainMenu\""#, options: [.regularExpression, .caseInsensitive]) != nil else {
                    continue
                }
                startLocation = match.range.location
                if isSelfClosing { return match.range }
                depth = 1
                continue
            }

            if isClosing {
                depth -= 1
                if depth == 0, let startLocation {
                    return NSRange(
                        location: startLocation,
                        length: NSMaxRange(match.range) - startLocation
                    )
                }
            } else if !isSelfClosing {
                depth += 1
            }
        }
        return nil
    }

    private func relativePath(for fileURL: URL, projectURL: URL) -> String {
        let root = projectURL.standardizedFileURL.path
        let file = fileURL.standardizedFileURL.path
        guard file.hasPrefix(root + "/") else { return fileURL.lastPathComponent }
        return String(file.dropFirst(root.count + 1))
    }

}
